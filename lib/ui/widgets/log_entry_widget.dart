import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/models/vpn_log_entry.dart';
import '../theme/app_colors.dart';

class LogEntryWidget extends StatelessWidget {
  final VpnLogEntry entry;
  static final _timeFmt = DateFormat('HH:mm:ss.SSS');

  const LogEntryWidget({super.key, required this.entry});

  Color get _levelColor => switch (entry.level) {
    LogLevel.debug => AppColors.logDebug,
    LogLevel.info => AppColors.logInfo,
    LogLevel.warning => AppColors.logWarning,
    LogLevel.error => AppColors.logError,
  };

  String get _levelLabel => switch (entry.level) {
    LogLevel.debug => 'DBG',
    LogLevel.info => 'INF',
    LogLevel.warning => 'WRN',
    LogLevel.error => 'ERR',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timestamp
          Text(
            _timeFmt.format(entry.timestamp),
            style: const TextStyle(color: AppColors.textDisabled, fontSize: 11),
          ),
          const SizedBox(width: 8),
          // Level badge
          Container(
            width: 30,
            padding: const EdgeInsets.symmetric(vertical: 1),
            decoration: BoxDecoration(
              color: _levelColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _levelLabel,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _levelColor,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Message
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                color: entry.level == LogLevel.error
                    ? AppColors.logError
                    : AppColors.textSecondary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
