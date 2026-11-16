import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import 'owner_properties.dart';
import 'owner_tools.dart';
import 'account_services.dart';
import 'session.dart';

class OwnerDashboard extends StatelessWidget {
  const OwnerDashboard({super.key});

  static const api = String.fromEnvironment('API_BASE_URL');
  static const navy = Color(0xFF14213D);

  Future<void> signOut(BuildContext context) async {
    final active = session.value;
    if (active == null) return;

    try {
      final response = await http
          .post(
            Uri.parse('$api/auth/logout'),
            headers: {'Authorization': 'Bearer ${active.token}'},
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw StateError('Logout failed');
      }

      session.value = null;
      if (context.mounted) context.go('/account');
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not log out. Try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'BoardEase Owner',
          style: TextStyle(color: navy, fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: () => signOut(context),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Owner Dashboard',
                  style: TextStyle(
                    color: navy,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Manage your properties and boarding house activity.',
                  style: TextStyle(color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final service in [AccountService.proofs, AccountService.notifications])
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(builder: (_) => AccountServicePage(service: service)),
                        ),
                        child: Text(service.title),
                      ),
                    for (final report in OwnerReport.values)
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => OwnerReportPage(report: report),
                          ),
                        ),
                        child: Text(report.title),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const OwnerProperties(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
