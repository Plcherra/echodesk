import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import '../services/api_client.dart';
import 'voice_clone_io.dart' if (dart.library.html) 'voice_clone_io_stub.dart';

/// Optional “Use my voice” control for receptionist Step 5 and settings.
class VoiceCloneSection extends StatefulWidget {
  const VoiceCloneSection({
    super.key,
    required this.selectedCloneId,
    required this.selectedCloneLabel,
    required this.onSelected,
    required this.onCleared,
    this.compact = false,
  });

  final String? selectedCloneId;
  final String? selectedCloneLabel;
  final void Function(String id, String label) onSelected;
  final VoidCallback onCleared;
  final bool compact;

  @override
  State<VoiceCloneSection> createState() => _VoiceCloneSectionState();
}

class _VoiceCloneSectionState extends State<VoiceCloneSection> {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  bool _recording = false;
  bool _busy = false;
  bool _consent = false;
  String? _error;
  String? _localPath;
  String? _pendingCloneId;
  String? _pendingLabel;

  bool get _canRecord =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  void dispose() {
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggleRecord() async {
    setState(() => _error = null);
    if (_recording) {
      final path = await _recorder.stop();
      setState(() {
        _recording = false;
        _localPath = path;
        _pendingCloneId = null;
      });
      return;
    }
    if (!await _recorder.hasPermission()) {
      setState(() => _error = 'Microphone permission is required to record.');
      return;
    }
    final dest = voiceCloneTempWavPath();
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav, numChannels: 1),
      path: dest,
    );
    setState(() {
      _recording = true;
      _localPath = dest;
      _pendingCloneId = null;
    });
  }

  Future<void> _pickFile() async {
    setState(() => _error = null);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['wav', 'mp3', 'm4a'],
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (kIsWeb) {
      if (file.bytes == null) return;
      setState(() {
        _pendingLabel = file.name;
        _pendingCloneId = null;
      });
      await _uploadBytes(file.bytes!, file.name);
      return;
    }
    if (file.path == null) return;
    setState(() {
      _localPath = file.path;
      _pendingCloneId = null;
      _pendingLabel = file.name;
    });
  }

  Future<void> _uploadBytes(Uint8List bytes, String filename) async {
    if (!_consent) {
      setState(() => _error = 'Check the consent box to clone your voice.');
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await ApiClient.postMultipart(
        '/api/mobile/voice-clones',
        fields: {
          'consent': 'true',
          'label': (_pendingLabel ?? 'My voice'),
        },
        files: [
          http.MultipartFile.fromBytes('audio', bytes, filename: filename),
        ],
      );
      await _handleUploadResponse(res);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not upload the sample.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _uploadLocal() async {
    if (!_consent) {
      setState(() => _error = 'Check the consent box to clone your voice.');
      return;
    }
    final path = _localPath;
    if (path == null) {
      setState(() => _error = 'Record or upload a 5–20 second sample first.');
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await ApiClient.postMultipart(
        '/api/mobile/voice-clones',
        fields: {
          'consent': 'true',
          'label': (_pendingLabel ?? 'My voice'),
        },
        files: [
          await http.MultipartFile.fromPath('audio', path, filename: 'sample.wav'),
        ],
      );
      await _handleUploadResponse(res);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not upload the sample.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _handleUploadResponse(http.Response res) async {
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final data = jsonDecode(res.body) as Map<String, dynamic>?;
      final id = data?['id'] as String?;
      final label = (data?['label'] as String?) ?? 'My voice';
      if (id != null) {
        setState(() {
          _pendingCloneId = id;
          _pendingLabel = label;
          _error = null;
        });
      } else {
        setState(() => _error = 'Clone was created but no id was returned.');
      }
    } else {
      Map<String, dynamic>? data;
      try {
        data = jsonDecode(res.body) as Map<String, dynamic>?;
      } catch (_) {}
      setState(() => _error = data?['error'] as String? ?? 'Clone failed.');
    }
  }

  Future<void> _previewPending() async {
    final id = _pendingCloneId ?? widget.selectedCloneId;
    if (id == null) return;
    final res = await ApiClient.get('/api/mobile/voice-clones/$id/preview');
    if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
      await _player.stop();
      await _player.setSource(BytesSource(res.bodyBytes, mimeType: 'audio/mpeg'));
      await _player.resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selectedCloneId != null;
    return Card(
      margin: const EdgeInsets.only(top: 8, bottom: 12),
      color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.compact ? 'Use my voice' : 'Optional: use my voice',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Record or upload 5–20 seconds in a quiet room. Skip to keep a professional voice.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (selected)
              Text(
                'Selected: ${widget.selectedCloneLabel ?? 'My voice'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _consent,
              onChanged: (v) => setState(() => _consent = v ?? false),
              title: const Text(
                'I confirm this is my voice and I consent to EchoDesk cloning it for my receptionist.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_canRecord)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _toggleRecord,
                    icon: Icon(_recording ? Icons.stop : Icons.mic),
                    label: Text(_recording ? 'Stop' : 'Record'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickFile,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload'),
                ),
                FilledButton.tonal(
                  onPressed: _busy || _recording ? null : _uploadLocal,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create clone'),
                ),
                if ((_pendingCloneId ?? widget.selectedCloneId) != null)
                  OutlinedButton(
                    onPressed: _busy ? null : _previewPending,
                    child: const Text('Preview'),
                  ),
                if (_pendingCloneId != null)
                  FilledButton(
                    onPressed: () => widget.onSelected(
                      _pendingCloneId!,
                      _pendingLabel ?? 'My voice',
                    ),
                    child: const Text('Use this voice'),
                  ),
                if (selected)
                  TextButton(
                    onPressed: widget.onCleared,
                    child: const Text('Use a preset instead'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
