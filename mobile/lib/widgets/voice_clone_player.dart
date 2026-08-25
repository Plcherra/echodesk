import 'package:flutter/material.dart';

import '../theme/echodesk_theme.dart';

String formatCloneClock(Duration d) {
  final total = d.inMilliseconds < 0 ? 0 : d.inSeconds;
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Compact in-card player for a recorded or uploaded clone sample.
class VoiceCloneSamplePlayer extends StatelessWidget {
  const VoiceCloneSamplePlayer({
    super.key,
    required this.position,
    required this.duration,
    required this.playing,
    required this.onPlayPause,
    required this.onSeek,
    this.label = 'Your sample',
    this.enabled = true,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final maxMs = duration.inMilliseconds <= 0 ? 1 : duration.inMilliseconds;
    final posMs = position.inMilliseconds.clamp(0, maxMs);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 8),
      decoration: BoxDecoration(
        color: EchoDeskColors.surfaceSoft,
        borderRadius: BorderRadius.circular(EchoDeskRadii.md),
        border: Border.all(color: EchoDeskColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: EchoDeskColors.muted,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Material(
                color: EchoDeskColors.brand,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: enabled ? onPlayPause : null,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                        activeTrackColor: EchoDeskColors.brand,
                        inactiveTrackColor: EchoDeskColors.lineStrong,
                        thumbColor: EchoDeskColors.brand,
                      ),
                      child: Slider(
                        min: 0,
                        max: maxMs.toDouble(),
                        value: posMs.toDouble(),
                        onChanged: enabled
                            ? (v) => onSeek(Duration(milliseconds: v.round()))
                            : null,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatCloneClock(position),
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: EchoDeskColors.soft,
                                ),
                          ),
                          Text(
                            formatCloneClock(duration),
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: EchoDeskColors.soft,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
