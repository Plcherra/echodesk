import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/wizard_form.dart';
import '../../models/bookable_hours.dart';
import '../../config/env.dart';
import '../../services/api_client.dart';
import '../../strings.dart';
import '../../widgets/bookable_hours_editor.dart';

const _steps = [
  'Basics',
  'Phone',
  'Instructions',
  'Hours & details',
  'Call behavior',
  'Review',
];

class CreateReceptionistScreen extends StatefulWidget {
  const CreateReceptionistScreen({super.key, this.firstRun = false});

  /// Opened from first-login onboarding — lighter framing, return via pop.
  final bool firstRun;

  @override
  State<CreateReceptionistScreen> createState() =>
      _CreateReceptionistScreenState();
}

class _CreateReceptionistScreenState extends State<CreateReceptionistScreen> {
  bool get _isPhoneDevice =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  int _step = 1;
  final _formData = WizardFormData(calendarId: 'primary');
  late final TextEditingController _systemPromptController;
  bool _promptCustomized = false;
  bool _loading = false;
  String? _error;
  String? _successId;
  String? _successPhone;
  String? _successName;
  bool _calendarsLoading = false;
  /// 'primary' | 'custom'
  String _calendarChoice = 'primary';
  String _primaryCalendarId = 'primary';
  String _primaryCalendarLabel = 'Primary calendar';
  late final TextEditingController _customCalendarController;
  List<Map<String, dynamic>> _voicePresets = [];
  bool _voicePresetsLoading = false;
  final AudioPlayer _previewPlayer = AudioPlayer();
  String? _previewPlayingKey;

  /// Active number-transfer evaluation request (pending_review | porting).
  Map<String, dynamic>? _activeTransfer;
  bool _transferLoading = false;
  bool _transferSubmitting = false;
  String _transferPhone = '';
  String? _transferKind; // mobile_carrier | voip_internet
  String _transferCarrier = '';
  String _transferNote = '';
  bool _transferStatusFetched = false;
  String? _transferPhoneError;
  String? _transferKindError;
  String? _transferCarrierError;

  /// Existing business line to reuse when adding another receptionist.
  bool _reusesSharedLine = false;
  String? _sharedLinePhone;

  /// Soft-deleted DID held for reclaim (from pending-release API).
  Map<String, dynamic>? _heldNumber;

  bool get _canGoNext {
    if (_loading) return false;
    if (_step == 2) {
      if (_reusesSharedLine) return true;
      if (_formData.phoneStrategy == 'reclaim' && _heldNumber != null) return true;
      // Only a new EchoDesk number can advance the wizard.
      return _formData.phoneStrategy == 'new' &&
          (_formData.areaCode != null && _formData.areaCode!.isNotEmpty);
    }
    if (_step == 6) return _formData.consent;
    return true;
  }

  bool get _transferFormReady {
    return _transferPhoneE164() != null &&
        _transferKind != null &&
        _transferCarrier.trim().isNotEmpty;
  }

  /// National digits only in the field; fixed +1 prefix for US/Canada.
  String? _transferPhoneE164() {
    final digits = _transferPhone.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    return null;
  }

  void _showVisibleError(String message) {
    setState(() => _error = message);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _systemPromptController =
        TextEditingController(text: _formData.systemPrompt);
    _customCalendarController =
        TextEditingController(text: _formData.calendarId);
    _loadDefaults();
  }

  @override
  void dispose() {
    _previewPlayer.dispose();
    _systemPromptController.dispose();
    _customCalendarController.dispose();
    super.dispose();
  }

  void _applyDefaultPrompt() {
    final prompt = defaultReceptionistPrompt(
      name: _formData.name,
      mode: _formData.mode,
    );
    _formData.systemPrompt = prompt;
    _systemPromptController.text = prompt;
    _promptCustomized = false;
  }

  void _goToStep(int step) {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    setState(() => _step = step);
  }

  Future<void> _loadVoicePresets() async {
    if (_voicePresets.isNotEmpty) return;
    setState(() => _voicePresetsLoading = true);
    try {
      final res = await ApiClient.get('/api/mobile/voice-presets');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        final list = data?['presets'] as List<dynamic>?;
        setState(() {
          _voicePresets = list?.cast<Map<String, dynamic>>() ?? [];
          _voicePresetsLoading = false;
        });
      } else {
        setState(() => _voicePresetsLoading = false);
      }
    } catch (_) {
      setState(() => _voicePresetsLoading = false);
    }
  }

  Future<void> _playPresetPreview(String key) async {
    if (_previewPlayingKey == key) {
      await _previewPlayer.stop();
      setState(() => _previewPlayingKey = null);
      return;
    }
    setState(() => _previewPlayingKey = key);
    try {
      final path = '/api/mobile/voice-presets/$key/preview';
      final res = await ApiClient.get(path);
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        await _previewPlayer.stop();
        await _previewPlayer
            .setSource(BytesSource(res.bodyBytes, mimeType: 'audio/mpeg'));
        await _previewPlayer.resume();
        _previewPlayer.onPlayerComplete.listen((_) {
          if (mounted) setState(() => _previewPlayingKey = null);
        });
      } else {
        if (mounted) setState(() => _previewPlayingKey = null);
      }
    } catch (_) {
      if (mounted) setState(() => _previewPlayingKey = null);
    }
  }

  Future<void> _loadDefaults() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    final supabase = Supabase.instance.client;
    final res = await supabase
        .from('users')
        .select('calendar_id, email')
        .eq('id', user.id)
        .maybeSingle();
    final profileCalendarId = (res?['calendar_id'] as String?)?.trim();
    final profileEmail = (res?['email'] as String?)?.trim() ??
        user.email?.trim();

    await _loadCalendarOptions(
      preferredId: profileCalendarId,
      fallbackEmail: profileEmail,
    );
    await _loadHeldNumber();

    try {
      final recs = await supabase
          .from('receptionists')
          .select(
            'phone_number, inbound_phone_number, telnyx_phone_number, '
            'telnyx_phone_number_id, deleted_at, status, active',
          )
          .eq('user_id', user.id)
          .order('created_at', ascending: true);

      var activeCount = 0;
      String? sharedPhone;
      var hasLine = false;
      for (final raw in (recs as List)) {
        final row = raw as Map<String, dynamic>;
        if (row['deleted_at'] != null) continue;
        if (row['status'] != null && row['status'] != 'active') continue;
        if (row['active'] == false) continue;
        activeCount += 1;
        final tid = (row['telnyx_phone_number_id'] as String?)?.trim() ?? '';
        final phone = ((row['inbound_phone_number'] as String?) ??
                    (row['telnyx_phone_number'] as String?) ??
                    (row['phone_number'] as String?) ??
                    '')
                .trim();
        if (tid.isNotEmpty || phone.isNotEmpty) {
          hasLine = true;
          sharedPhone = phone.isNotEmpty ? phone : sharedPhone;
          if (tid.isNotEmpty && phone.isNotEmpty) break;
        }
      }

      // One assistant per account/line — use Staff/Locations instead of a second create.
      if (mounted && activeCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'You already have an assistant. Open Settings to switch Solo/Business '
              'and add staff or store locations.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/receptionists');
        }
        return;
      }

      if (mounted && hasLine) {
        setState(() {
          _reusesSharedLine = true;
          _sharedLinePhone = sharedPhone;
          _formData.phoneStrategy = 'new';
        });
      }
    } catch (_) {
      // Non-fatal — create can still proceed.
    }
  }

  Future<void> _loadCalendarOptions({
    String? preferredId,
    String? fallbackEmail,
  }) async {
    if (!mounted) return;
    setState(() => _calendarsLoading = true);

    String? primaryId;
    String? primaryLabel;
    try {
      final res = await ApiClient.get('/api/mobile/google/calendars');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        final list = data?['calendars'] as List<dynamic>? ?? [];
        for (final raw in list) {
          if (raw is! Map) continue;
          final id = (raw['id'] ?? '').toString().trim();
          if (id.isEmpty) continue;
          final summary = (raw['summary'] ?? id).toString().trim();
          final idL = id.toLowerCase();
          final summaryL = summary.toLowerCase();
          if (idL.contains('#holiday') ||
              idL.contains('holiday@group') ||
              summaryL.contains('holidays in') ||
              summaryL.startsWith('holidays ')) {
            continue;
          }
          if (raw['primary'] == true) {
            primaryId = id;
            primaryLabel = id.contains('@')
                ? 'Primary · $id'
                : 'Primary · $summary';
            break;
          }
        }
      }
    } catch (_) {
      // Fallbacks below.
    }

    final preferred = (preferredId ?? '').trim();
    final email = (fallbackEmail ?? '').trim();
    primaryId ??= preferred.isNotEmpty
        ? preferred
        : (email.contains('@') ? email : 'primary');
    primaryLabel ??= email.contains('@')
        ? 'Primary · $email'
        : 'Primary calendar';

    final current = _formData.calendarId.trim();
    final isPrimary = current.isEmpty ||
        current == 'primary' ||
        current == primaryId ||
        (email.isNotEmpty && current == email);

    if (!mounted) return;
    setState(() {
      _primaryCalendarId = primaryId!;
      _primaryCalendarLabel = primaryLabel!;
      _calendarChoice = isPrimary ? 'primary' : 'custom';
      if (isPrimary) {
        _formData.calendarId = _primaryCalendarId;
        _customCalendarController.text = _primaryCalendarId;
      } else {
        _customCalendarController.text = current;
      }
      _calendarsLoading = false;
    });
  }

  void _setCalendarChoice(String choice) {
    setState(() {
      _calendarChoice = choice;
      if (choice == 'primary') {
        _formData.calendarId = _primaryCalendarId;
      } else {
        _formData.calendarId = _customCalendarController.text.trim();
      }
    });
  }

  Future<void> _loadHeldNumber() async {
    try {
      final res =
          await ApiClient.get('/api/mobile/phone-numbers/pending-release');
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>?;
      final nums = data?['numbers'] as List<dynamic>? ?? [];
      if (nums.isEmpty) return;
      final first = nums.first;
      if (first is! Map) return;
      final held = Map<String, dynamic>.from(first);
      if (!mounted) return;
      setState(() {
        _heldNumber = held;
        // Default: keep the held number instead of buying another DID.
        if (!_reusesSharedLine) {
          _formData.phoneStrategy = 'reclaim';
        }
      });
    } catch (_) {
      // Non-fatal — create still works with a new number.
    }
  }

  int _nextStepFrom(int step) {
    final n = step + 1;
    if (n == 2 && _reusesSharedLine) return 3;
    return n;
  }

  int _prevStepFrom(int step) {
    final n = step - 1;
    if (n == 2 && _reusesSharedLine) return 1;
    return n;
  }

  bool _validateStep() {
    if (_step == 1) {
      if (_formData.name.trim().isEmpty) {
        _showVisibleError('Name is required');
        return false;
      }
      if (_calendarChoice == 'primary') {
        _formData.calendarId = _primaryCalendarId;
      } else {
        _formData.calendarId = _customCalendarController.text.trim();
      }
      if (_calendarChoice == 'custom' &&
          _customCalendarController.text.trim().isEmpty) {
        _showVisibleError('Enter a custom calendar ID');
        return false;
      }
      if (_formData.calendarId.trim().isEmpty) {
        _showVisibleError('Calendar ID is required');
        return false;
      }
      return true;
    }
    if (_step == 4) {
      final hoursErr = _formData.bookableHours.validationError();
      if (hoursErr != null) {
        _showVisibleError(hoursErr);
        return false;
      }
      return true;
    }
    if (_step == 2) {
      if (_reusesSharedLine) return true;
      if (_formData.phoneStrategy == 'reclaim' && _heldNumber != null) {
        return true;
      }
      if (_formData.phoneStrategy != 'new') {
        _showVisibleError(
          _activeTransfer != null
              ? AppStrings.transferMustUseNewNumber
              : AppStrings.transferSelectNewToContinue,
        );
        return false;
      }
      if (_formData.areaCode == null || _formData.areaCode!.isEmpty) {
        _showVisibleError('Please select an area code');
        return false;
      }
      return true;
    }
    if (_step == 3) {
      if (_formData.systemPrompt.trim().isEmpty) {
        _showVisibleError('System prompt is required');
        return false;
      }
      return true;
    }
    if (_step == 5) {
      return true;
    }
    if (_step == 6) {
      if (!_formData.consent) {
        _showVisibleError('Consent is required');
        return false;
      }
      return true;
    }
    return true;
  }

  Future<void> _submit() async {
    if (!_validateStep()) return;

    setState(() {
      _error = null;
      _loading = true;
    });

    try {
      final res = await ApiClient.post(
        '/api/mobile/receptionists/create',
        body: _formData.toApiBody(),
      );

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _successId = data['id'] as String?;
          _successPhone = data['phoneNumber'] as String?;
          _successName = _formData.name;
          _loading = false;
        });
      } else {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _loading = false);
        _showVisibleError(
          data['error'] as String? ?? 'Failed to create receptionist',
        );
      }
    } catch (e) {
      setState(() => _loading = false);
      _showVisibleError(AppStrings.somethingWentWrong);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_successId != null) {
      return _buildSuccessState();
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.firstRun ? 'Your AI receptionist' : 'Add Receptionist',
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            if (widget.firstRun && context.canPop()) {
              context.pop(false);
            } else {
              context.go('/receptionists');
            }
          },
        ),
      ),
      body: Column(
        children: [
          if (widget.firstRun)
            Material(
              color: Theme.of(context).colorScheme.secondaryContainer
                  .withValues(alpha: 0.55),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.flag_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Step 2 of setup · About 3 minutes',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSecondaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          _buildStepper(),
          if (_error != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _error = null),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                SystemChannels.textInput.invokeMethod('TextInput.hide');
              },
              child: ListView(
                padding: const EdgeInsets.all(24),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (_step == 1) _buildStep1(),
                  if (_step == 2) _buildStep2(),
                  if (_step == 3) _buildStep3(),
                  if (_step == 4) _buildStep4(),
                  if (_step == 5) _buildStep5(),
                  if (_step == 6) _buildStep6(),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_step == 2 && !_canGoNext && !_reusesSharedLine)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _activeTransfer != null
                            ? AppStrings.transferMustUseNewNumber
                            : AppStrings.transferSelectNewToContinue,
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (_step > 1)
                        OutlinedButton(
                          onPressed: _loading
                              ? null
                              : () {
                                  _error = null;
                                  _goToStep(_prevStepFrom(_step));
                                },
                          child: const Text('Back'),
                        )
                      else
                        const SizedBox(),
                      Row(
                        children: [
                          if (_step == 4 || _step == 5)
                            TextButton(
                              onPressed: () {
                                _error = null;
                                _goToStep(_nextStepFrom(_step));
                              },
                              child: const Text('Skip'),
                            ),
                          FilledButton(
                            onPressed: !_canGoNext
                                ? null
                                : () async {
                                    if (_step < 6) {
                                      if (_validateStep()) {
                                        _error = null;
                                        _goToStep(_nextStepFrom(_step));
                                      }
                                    } else {
                                      await _submit();
                                    }
                                  },
                            child: _loading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : Text(
                                    _step == 6
                                        ? 'Create Receptionist'
                                        : 'Next',
                                  ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepper() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              for (var i = 0; i < _steps.length; i++) ...[
                GestureDetector(
                  onTap: i + 1 < _step
                      ? () {
                          _error = null;
                          _goToStep(i + 1);
                        }
                      : null,
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: _step > i + 1
                        ? Colors.green
                        : _step == i + 1
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.shade300,
                    child: Text(
                      _step > i + 1 ? '✓' : '${i + 1}',
                      style: TextStyle(
                        color: _step >= i + 1
                            ? Colors.white
                            : Colors.grey.shade700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                if (i < _steps.length - 1)
                  Expanded(
                    child: Container(
                      height: 2,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      color:
                          _step > i + 1 ? Colors.green : Colors.grey.shade300,
                    ),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Step $_step of 6: ${_steps[_step - 1]}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _selectableOption({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildStep1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Who is this assistant for?',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        _selectableOption(
          title: 'Personal / Solo',
          subtitle:
              'Book time on my calendar. One receptionist, one phone number.',
          selected: _formData.mode == 'personal',
          onTap: () => setState(() {
            _formData.mode = 'personal';
            if (!_promptCustomized) _applyDefaultPrompt();
          }),
        ),
        _selectableOption(
          title: 'Business / Team',
          subtitle:
              'Staff, services, and store locations — each can use its own calendar. Same phone number.',
          selected: _formData.mode == 'business',
          onTap: () => setState(() {
            _formData.mode = 'business';
            if (!_promptCustomized) _applyDefaultPrompt();
          }),
        ),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: _formData.name,
          decoration: const InputDecoration(
            labelText: 'Receptionist name',
            hintText: 'e.g. Eve, Alex, My AI Receptionist',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            _formData.name = v;
            if (!_promptCustomized) {
              setState(_applyDefaultPrompt);
            }
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _formData.country,
          decoration: const InputDecoration(
            labelText: 'Country',
            border: OutlineInputBorder(),
          ),
          items: countryOptions
              .map(
                  (o) => DropdownMenuItem(value: o.value, child: Text(o.label)))
              .toList(),
          onChanged: (v) => setState(() => _formData.country = v ?? 'US'),
        ),
        const SizedBox(height: 16),
        if (_calendarsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        Text(
          'Google calendar',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: _calendarChoice,
          onChanged: (v) {
            if (v == null) return;
            _setCalendarChoice(v);
          },
          child: Column(
            children: [
              RadioListTile<String>(
                value: 'primary',
                title: Text(
                  _primaryCalendarLabel,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: const Text(
                  'Your Google primary calendar (usually your email).',
                ),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              RadioListTile<String>(
                value: 'custom',
                title: const Text('Custom calendar ID'),
                subtitle: const Text(
                  'Paste another Google Calendar ID if you use a shared or secondary calendar.',
                ),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            ],
          ),
        ),
        if (_calendarChoice == 'custom') ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: _customCalendarController,
            decoration: const InputDecoration(
              labelText: 'Calendar ID',
              hintText: 'name@group.calendar.google.com',
              helperText:
                  'Find it in Google Calendar → Settings → Integrate calendar.',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              setState(() => _formData.calendarId = v.trim());
            },
          ),
        ],
      ],
    );
  }

  Future<void> _loadActiveTransfer() async {
    if (_transferLoading) return;
    setState(() => _transferLoading = true);
    try {
      final res = await ApiClient.get('/api/mobile/number-transfers/active');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        final req = data?['request'] as Map<String, dynamic>?;
        if (!mounted) return;
        setState(() {
          _activeTransfer = req;
          _transferStatusFetched = true;
          _transferLoading = false;
          if (req != null && _heldNumber == null) {
            // Keep user on the only completable path when no held number.
            _formData.phoneStrategy = 'new';
          }
        });
      } else {
        if (mounted) {
          setState(() {
            _transferStatusFetched = true;
            _transferLoading = false;
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _transferStatusFetched = true;
          _transferLoading = false;
        });
      }
    }
  }

  Future<void> _submitTransferRequest() async {
    setState(() {
      _error = null;
      _transferPhoneError = null;
      _transferKindError = null;
      _transferCarrierError = null;
    });

    final normalized = _transferPhoneE164();
    String? phoneErr;
    String? kindErr;
    String? carrierErr;
    if (normalized == null) {
      phoneErr = 'Enter a 10-digit US/Canada number';
    }
    if (_transferKind == null) {
      kindErr = 'Select mobile/carrier or internet/VoIP.';
    }
    final carrier = _transferCarrier.trim();
    if (carrier.isEmpty) {
      carrierErr = 'Tell us the carrier or provider (e.g. T-Mobile, Twilio).';
    }

    if (phoneErr != null || kindErr != null || carrierErr != null) {
      setState(() {
        _transferPhoneError = phoneErr;
        _transferKindError = kindErr;
        _transferCarrierError = carrierErr;
      });
      _showVisibleError(
        phoneErr ?? kindErr ?? carrierErr ?? AppStrings.couldNotSubmitTransfer,
      );
      return;
    }

    setState(() => _transferSubmitting = true);
    try {
      final res = await ApiClient.post(
        '/api/mobile/number-transfers',
        body: {
          'phone': normalized,
          'number_kind': _transferKind,
          'carrier_or_provider': carrier,
          if (_transferNote.trim().isNotEmpty)
            'customer_note': _transferNote.trim(),
        },
      );
      if (!mounted) return;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final req = data['request'] as Map<String, dynamic>?;
        setState(() {
          _activeTransfer = req;
          _transferSubmitting = false;
          _formData.phoneStrategy = 'new';
          _error = null;
          _transferPhoneError = null;
          _transferKindError = null;
          _transferCarrierError = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(AppStrings.transferSubmitted),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 5),
          ),
        );
      } else {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        setState(() => _transferSubmitting = false);
        _showVisibleError(
          data?['error'] as String? ?? AppStrings.couldNotSubmitTransfer,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _transferSubmitting = false);
        _showVisibleError(AppStrings.couldNotSubmitTransfer);
      }
    }
  }

  String _transferKindLabel(String? kind) {
    switch (kind) {
      case 'mobile_carrier':
        return 'Mobile / carrier phone';
      case 'voip_internet':
        return 'Internet / VoIP';
      default:
        return kind ?? '—';
    }
  }

  Widget _buildStep2() {
    if (_reusesSharedLine) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Business phone line'),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Uses your existing business number',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _sharedLinePhone ?? 'Shared business line',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'All receptionists for this account share one phone line. '
                    'Solo vs business only changes booking setup — not the number.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (!_transferStatusFetched && !_transferLoading) {
      _loadActiveTransfer();
    }
    final underReview = _activeTransfer != null;
    final supportEmail = Env.supportEmail;
    final heldDisplay = (_heldNumber?['phone_display'] as String?)?.trim().isNotEmpty == true
        ? _heldNumber!['phone_display'] as String
        : (_heldNumber?['phone_number'] as String? ?? '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _heldNumber != null
              ? 'How should we set up the phone line?'
              : 'How do you want to set up your business phone line?',
        ),
        const SizedBox(height: 16),
        if (_heldNumber != null) ...[
          _selectableOption(
            title: 'Keep $heldDisplay',
            subtitle:
                'Attach this held number to your new receptionist.',
            selected: _formData.phoneStrategy == 'reclaim',
            onTap: () => setState(() => _formData.phoneStrategy = 'reclaim'),
          ),
          _selectableOption(
            title: 'Get a different new number',
            subtitle:
                'Set up a new US business number. Your held number stays available to release later.',
            selected: _formData.phoneStrategy == 'new',
            onTap: () => setState(() => _formData.phoneStrategy = 'new'),
          ),
        ] else
          _selectableOption(
            title: 'Get a new business number',
            subtitle:
                "We'll set up a US business number for you. Ready quickly.",
            selected: _formData.phoneStrategy == 'new',
            onTap: () => setState(() => _formData.phoneStrategy = 'new'),
          ),
        if (_formData.phoneStrategy == 'new')
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 8),
            child: DropdownButtonFormField<String>(
              initialValue: _formData.areaCode ?? '212',
              decoration: const InputDecoration(
                labelText: 'Preferred area code',
                border: OutlineInputBorder(),
              ),
              items: areaCodes
                  .map((o) =>
                      DropdownMenuItem(value: o.value, child: Text(o.label)))
                  .toList(),
              onChanged: (v) => setState(() => _formData.areaCode = v ?? '212'),
            ),
          ),
        _selectableOption(
          title: underReview
              ? 'Transfer a number I already have (under review)'
              : 'Transfer a number I already have',
          subtitle: underReview
              ? AppStrings.transferUnderReview
              : 'Tell us about the number you use today. We’ll review whether we can move it to EchoDesk. Meanwhile, get a temporary number so you can start.',
          selected: _formData.phoneStrategy == 'transfer',
          onTap: underReview
              ? () {}
              : () => setState(() => _formData.phoneStrategy = 'transfer'),
        ),
        if (_transferLoading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (underReview)
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 8, bottom: 8),
            child: Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Under review',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _activeTransfer!['phone_number_e164'] as String? ?? '—',
                    ),
                    Text(
                      '${_transferKindLabel(_activeTransfer!['number_kind'] as String?)} · '
                      '${_activeTransfer!['carrier_or_provider'] as String? ?? '—'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      AppStrings.transferUnderReview,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (_formData.phoneStrategy == 'transfer')
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  initialValue: _transferPhone,
                  decoration: InputDecoration(
                    labelText: 'Phone number',
                    hintText: '5551234567',
                    prefixText: '+1 ',
                    helperText:
                        'US/Canada. Other countries? Email us below.',
                    errorText: _transferPhoneError,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(10),
                  ],
                  onChanged: (v) => setState(() {
                    _transferPhone = v;
                    _transferPhoneError = null;
                  }),
                ),
                const SizedBox(height: 12),
                Text(
                  'Number type',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mobile / carrier phone'),
                  subtitle: const Text('T‑Mobile, AT&T, Verizon, etc.'),
                  value: 'mobile_carrier',
                  groupValue: _transferKind,
                  onChanged: (v) => setState(() {
                    _transferKind = v;
                    _transferKindError = null;
                  }),
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Internet / VoIP'),
                  subtitle: const Text('Twilio, Telnyx, other business phone'),
                  value: 'voip_internet',
                  groupValue: _transferKind,
                  onChanged: (v) => setState(() {
                    _transferKind = v;
                    _transferKindError = null;
                  }),
                ),
                if (_transferKindError != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, bottom: 8),
                    child: Text(
                      _transferKindError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: _transferCarrier,
                  decoration: InputDecoration(
                    labelText: 'Carrier or provider',
                    hintText: 'e.g. T-Mobile, AT&T, Twilio, Telnyx',
                    errorText: _transferCarrierError,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() {
                    _transferCarrier = v;
                    _transferCarrierError = null;
                  }),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: _transferNote,
                  decoration: const InputDecoration(
                    labelText: 'Anything else we should know (optional)',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 3,
                  onChanged: (v) => _transferNote = v,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: (_transferSubmitting || !_transferFormReady)
                      ? null
                      : _submitTransferRequest,
                  child: _transferSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Submit for review'),
                ),
                if (!_transferFormReady && !_transferSubmitting)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Fill phone, number type, and carrier to enable submit.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Text(
          'Questions about moving your number? Email us.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        TextButton.icon(
          onPressed: () => launchUrl(
            Uri.parse(
              'mailto:$supportEmail?subject=${Uri.encodeComponent('EchoDesk number transfer')}',
            ),
          ),
          icon: const Icon(Icons.email_outlined, size: 18),
          label: Text(supportEmail),
        ),
      ],
    );
  }

  Widget _buildStep3() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Core instructions for your receptionist'),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(_applyDefaultPrompt),
          child: const Text('Use default prompt'),
        ),
        TextField(
          controller: _systemPromptController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            helperText:
                'Default uses the receptionist name from Step 1. Edit anytime.',
          ),
          maxLines: 6,
          onChanged: (v) {
            _formData.systemPrompt = v;
            _promptCustomized = true;
          },
        ),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: _formData.greeting,
          decoration: const InputDecoration(
            labelText: 'Greeting (optional)',
            hintText:
                "e.g. Hello! Thanks for calling. I'm Eve. How can I help you today?",
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
          onChanged: (v) => _formData.greeting = v,
        ),
      ],
    );
  }

  Widget _buildStep4() {
    // Personal: optional services only. Business: existing staff/services/locations/promos fields.
    if (_formData.mode == 'personal') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BookableHoursEditor(
            value: _formData.bookableHours,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 24),
          const Text('Services (optional)'),
          const SizedBox(height: 8),
          const Text(
            'Add services you offer so your assistant can suggest durations automatically. '
            'If you skip this, the assistant will book generic appointments and ask for duration.',
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Services'),
              TextButton.icon(
                onPressed: () => setState(() {
                  _formData.services.add(
                    ServiceItem(
                      name: '',
                      description: '',
                      durationMinutes: null,
                      priceCents: null,
                      requiresLocation: false,
                      defaultLocationType: null,
                    ),
                  );
                }),
                icon: const Icon(Icons.add),
                label: const Text('Add service'),
              ),
            ],
          ),
          ..._formData.services.asMap().entries.map((e) {
            final i = e.key;
            final s = e.value;
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          initialValue: s.name,
                          decoration: const InputDecoration(
                            hintText: 'Service name',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) {
                            _formData.services[i] = ServiceItem(
                              name: v,
                              description: s.description,
                              durationMinutes: s.durationMinutes,
                              priceCents: s.priceCents,
                              requiresLocation: s.requiresLocation,
                              defaultLocationType: s.defaultLocationType,
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: TextFormField(
                          initialValue: s.description,
                          decoration: const InputDecoration(
                            hintText: 'Description',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) {
                            _formData.services[i] = ServiceItem(
                              name: s.name,
                              description: v,
                              durationMinutes: s.durationMinutes,
                              priceCents: s.priceCents,
                              requiresLocation: s.requiresLocation,
                              defaultLocationType: s.defaultLocationType,
                            );
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () =>
                            setState(() => _formData.services.removeAt(i)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SizedBox(
                        width: 180,
                        child: CheckboxListTile(
                          title: const Text('Requires location',
                              style: TextStyle(fontSize: 14)),
                          value: s.requiresLocation,
                          onChanged: (v) {
                            _formData.services[i] = ServiceItem(
                              name: s.name,
                              description: s.description,
                              durationMinutes: s.durationMinutes,
                              priceCents: s.priceCents,
                              requiresLocation: v ?? false,
                              defaultLocationType: s.defaultLocationType,
                            );
                            setState(() {});
                          },
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                      ),
                      if (s.requiresLocation) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue:
                                s.defaultLocationType ?? 'customer_address',
                            decoration: const InputDecoration(
                              labelText: 'Location type',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            isExpanded: true,
                            items: locationTypeOptions
                                .where((o) => o.value != 'no_location')
                                .map((o) => DropdownMenuItem(
                                    value: o.value, child: Text(o.label)))
                                .toList(),
                            onChanged: (v) {
                              _formData.services[i] = ServiceItem(
                                name: s.name,
                                description: s.description,
                                durationMinutes: s.durationMinutes,
                                priceCents: s.priceCents,
                                requiresLocation: s.requiresLocation,
                                defaultLocationType: v,
                              );
                              setState(() {});
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            );
          }),
          if (_formData.services.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Defaults (optional)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
              'You can edit duration, price, and location settings later from the Services screen.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BookableHoursEditor(
          value: _formData.bookableHours,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 24),
        const Text('Business details (optional)'),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Staff members'),
            TextButton.icon(
              onPressed: () => setState(() {
                _formData.staff.add(StaffItem(name: '', description: ''));
              }),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ],
        ),
        ..._formData.staff.asMap().entries.map((e) {
          final i = e.key;
          final s = e.value;
          return Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: s.name,
                  decoration: const InputDecoration(
                    hintText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _formData.staff[i] =
                      StaffItem(name: v, description: s.description),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  initialValue: s.description,
                  decoration: const InputDecoration(
                    hintText: 'Role or specialty',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _formData.staff[i] =
                      StaffItem(name: s.name, description: v),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => setState(() => _formData.staff.removeAt(i)),
              ),
            ],
          );
        }),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: _formData.promotions,
          decoration: const InputDecoration(
            labelText: 'Current promotions',
            hintText: 'e.g. 20% off first visit with code WELCOME20',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
          onChanged: (v) => _formData.promotions = v,
        ),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: _formData.extraInstructions,
          decoration: const InputDecoration(
            labelText: 'Extra notes for AI',
            hintText: 'e.g. Cancellation policy, parking notes',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
          maxLines: 3,
          onChanged: (v) => _formData.extraInstructions = v,
        ),
      ],
    );
  }

  Widget _buildStep5() {
    if (_voicePresets.isEmpty && !_voicePresetsLoading) {
      _loadVoicePresets();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Call behavior (optional)'),
        const SizedBox(height: 16),
        const Text(
          'Choose a voice',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'How your receptionist sounds — name and voice are separate choices.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (_voicePresetsLoading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          ..._voicePresets.map((p) {
            final key = p['key'] as String? ?? '';
            final label = p['label'] as String? ?? key;
            final description = p['description'] as String? ?? '';
            final selected = _formData.voicePresetKey == key;
            final playing = _previewPlayingKey == key;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              color: selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: InkWell(
                onTap: () => setState(() => _formData.voicePresetKey = key),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (description.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                description,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          playing ? Icons.stop : Icons.play_circle_outline,
                        ),
                        onPressed: () => _playPresetPreview(key),
                        tooltip: playing ? 'Stop' : 'Preview',
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildStep6() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Review & create'),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ReviewRow('Name', _formData.name),
                _ReviewRow('Country', _formData.country),
                _ReviewRow('Calendar', _formData.calendarId),
                _ReviewRow(
                  'Phone',
                  _reusesSharedLine
                      ? 'Shared line (${_sharedLinePhone ?? 'existing'})'
                      : _formData.phoneStrategy == 'reclaim' && _heldNumber != null
                          ? 'Keep held (${(_heldNumber!['phone_display'] as String?) ?? (_heldNumber!['phone_number'] as String?) ?? 'number'})'
                          : 'New number (${_formData.areaCode ?? '—'})',
                ),
                _ReviewRow(
                  'Prompt',
                  '${(_formData.systemPrompt).substring(0, _formData.systemPrompt.length.clamp(0, 80))}...',
                ),
                _ReviewRow(
                  'Voice',
                  () {
                    final found = _voicePresets
                        .where((p) => p['key'] == _formData.voicePresetKey);
                    return found.isEmpty
                        ? (_formData.voicePresetKey ?? 'Default')
                        : (found.first['label'] as String? ?? 'Default');
                  }(),
                ),
                _ReviewRow('Hours', _bookableHoursSummary()),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        CheckboxListTile(
          title: const Text(
            'I confirm that I have obtained all necessary consents for call recording and AI interaction in my jurisdiction.',
          ),
          value: _formData.consent,
          onChanged: (v) => setState(() {
            _formData.consent = v ?? false;
            if (_formData.consent) _error = null;
          }),
          controlAffinity: ListTileControlAffinity.leading,
        ),
      ],
    );
  }

  String _bookableHoursSummary() {
    final openDays = <String>[];
    for (final key in BookableHours.dayKeys) {
      final day = _formData.bookableHours.weekly[key];
      if (day == null || !day.open) continue;
      final label = BookableHours.dayLabels[key]!.substring(0, 3);
      openDays.add(
        '$label ${formatHhMm(day.startMinutes)}–${formatHhMm(day.endMinutes)}',
      );
    }
    if (openDays.isEmpty) return 'No open days';
    return openDays.join(', ');
  }

  Widget _buildSuccessState() {
    return Scaffold(
      appBar: AppBar(
        leading: const SizedBox(),
        title: const Text('Success'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 64),
            const SizedBox(height: 24),
            Text(
              'Receptionist created!',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text('"$_successName" is ready to take calls.'),
            if (_successPhone != null) ...[
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Text('Your business line'),
                      const SizedBox(height: 8),
                      SelectableText(
                        _successPhone!,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Customers call this number; your assistant answers on your business’s behalf.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      if (!_isPhoneDevice)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'Call this number from your phone to test the AI.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: _successPhone ?? ''),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Copied!')),
                              );
                            },
                            icon: const Icon(Icons.copy),
                            label: const Text('Copy'),
                          ),
                          if (_isPhoneDevice) ...[
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: () => launchUrl(
                                Uri.parse('tel:$_successPhone'),
                                mode: LaunchMode.externalApplication,
                              ),
                              icon: const Icon(Icons.phone),
                              label: const Text('Test call'),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 32),
            if (widget.firstRun) ...[
              FilledButton(
                onPressed: () {
                  if (context.canPop()) {
                    context.pop(true);
                  } else {
                    context.go('/onboarding');
                  }
                },
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Continue setup'),
              ),
            ] else
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () {
                      if (context.canPop()) {
                        context.pop(true);
                      } else {
                        context.go('/receptionists');
                      }
                    },
                    child: const Text('Done'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _successId != null
                        ? () => context.go('/receptionists/${_successId!}')
                        : null,
                    child: const Text('View receptionist'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  final String label;
  final String value;

  const _ReviewRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
