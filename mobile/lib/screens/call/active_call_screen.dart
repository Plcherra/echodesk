import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../config/env.dart';
import '../../services/call_service.dart';

/// Screen shown when user taps Accept on incoming call UI.
/// Displays call info and can connect to WebSocket stream for listen-in.
class ActiveCallScreen extends StatefulWidget {
  final String callSid;
  final String receptionistId;
  final String caller;

  const ActiveCallScreen({
    super.key,
    required this.callSid,
    required this.receptionistId,
    required this.caller,
  });

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  WebSocketChannel? _channel;
  String _status = 'Connecting...';
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    _connectToStream();
  }

  Future<void> _connectToStream() async {
    final wsBase = Env.voiceWsBaseUrl;
    if (wsBase.isEmpty) {
      setState(() {
        _status = 'Call in progress with AI receptionist';
      });
      return;
    }

    try {
      final uri = Uri.parse(
        '$wsBase/api/voice/stream?call_sid=${widget.callSid}&direction=listen',
      );
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;

      setState(() {
        _status = 'Connecting to call stream...';
      });

      channel.stream.listen(
        (_) {
          if (mounted) {
            setState(() => _status = 'Connected to call stream');
          }
        },
        onError: (e) {
          setState(() {
            _status = 'Stream disconnected';
          });
        },
        onDone: () {
          setState(() {
            _status = 'Call ended';
          });
        },
      );
    } catch (e) {
      setState(() {
        _status = 'Call in progress (stream unavailable)';
      });
    }
  }

  Future<void> _hangup() async {
    if (_ending) return;
    setState(() => _ending = true);
    try {
      await CallService().endCall(widget.callSid);
      if (mounted) context.pop();
    } finally {
      if (mounted) setState(() => _ending = false);
    }
  }

  /// End asks for confirmation so a stray tap doesn't hang up mid-call.
  Future<void> _confirmHangup() async {
    if (_ending) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End this call?'),
        content: const Text(
          'This hangs up the call for everyone. The AI receptionist will stop '
          'talking to the caller.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep talking'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('End call'),
          ),
        ],
      ),
    );
    if (ok == true) await _hangup();
  }

  /// Back must not silently leave and strand call UI / stream state.
  /// Offer Stay, Leave screen only, or End call.
  Future<void> _onBackPressed() async {
    if (_ending) return;
    final action = await showDialog<_LeaveAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave active call?'),
        content: const Text(
          'Leaving this screen does not hang up by itself. Choose whether to '
          'keep listening, leave the screen, or end the call.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveAction.stay),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_LeaveAction.leave),
            child: const Text('Leave screen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(_LeaveAction.end),
            child: const Text('End call'),
          ),
        ],
      ),
    );
    if (!mounted || action == null || action == _LeaveAction.stay) return;
    if (action == _LeaveAction.end) {
      await _hangup();
      return;
    }
    context.pop();
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onBackPressed();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Active Call'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _ending ? null : _onBackPressed,
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.phone_in_talk, size: 64, color: Colors.green),
                const SizedBox(height: 24),
                Text(
                  'Call in progress',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                if (widget.caller.isNotEmpty)
                  Text(
                    'From: ${widget.caller}',
                    style: Theme.of(context).textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _status,
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _ending ? null : _confirmHangup,
                  icon: _ending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.call_end),
                  label: Text(_ending ? 'Ending…' : 'End'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _LeaveAction { stay, leave, end }
