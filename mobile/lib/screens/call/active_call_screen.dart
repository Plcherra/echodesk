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
    await CallService().endCall(widget.callSid);
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Active Call'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
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
                onPressed: _hangup,
                icon: const Icon(Icons.call_end),
                label: const Text('End'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
