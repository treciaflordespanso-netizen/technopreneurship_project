import 'session.dart';
import 'auth_page.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import 'owner_dashboard.dart';
import 'room_availability.dart';
import 'account_services.dart';

const navy = Color(0xFF14213D);
const blue = Color(0xFF2563EB);
const background = Color(0xFFF8FAFC);

// Set this when the backend API is ready.
const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

final propertiesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  if (apiBaseUrl.isEmpty) {
    return [];
  }

  final client = http.Client();
  ref.onDispose(client.close);

  final response = await client
      .get(Uri.parse('$apiBaseUrl/properties'))
      .timeout(const Duration(seconds: 15));

  if (response.statusCode != 200) {
    throw Exception('Unable to load properties. Please try again.');
  }

  final decoded = jsonDecode(response.body);

  if (decoded is! List) {
    throw const FormatException('Unexpected property response.');
  }

  return decoded.map((item) => Map<String, dynamic>.from(item as Map)).toList();
});

final router = GoRouter(
  refreshListenable: session,
  redirect: (context, state) {
    if (state.uri.path == '/owner' && session.value?.role != 'owner') {
      return '/account';
    }
    if (state.uri.path == '/my-reservations' && session.value?.role != 'tenant') {
      return '/account';
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/owner',
      builder: (context, state) => const OwnerDashboard(),
    ),
    GoRoute(
      path: '/properties/:propertyId',
      builder: (_, state) {
        final id = int.tryParse(state.pathParameters['propertyId'] ?? '');
        return id == null
            ? const Scaffold(body: Center(child: Text('Property not found.')))
            : PublicPropertyRoomsPage(propertyId: id);
      },
    ),
    GoRoute(
      path: '/my-reservations',
      builder: (_, _) => const ReservationListPage(path: '/tenant/reservations'),
    ),
    GoRoute(path: '/', builder: (context, state) => const ExplorePage()),
    GoRoute(path: '/account', builder: (context, state) => const AuthPage()),
  ],
);
void main() {
  runApp(const ProviderScope(child: BoardEaseApp()));
}

class BoardEaseApp extends StatelessWidget {
  const BoardEaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'BoardEase',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: blue,
          surface: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.all(18),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
        ),
      ),
    );
  }
}

class ExplorePage extends ConsumerStatefulWidget {
  const ExplorePage({super.key});

  @override
  ConsumerState<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends ConsumerState<ExplorePage> {
  String search = '';

  @override
  Widget build(BuildContext context) {
    final properties = ref.watch(propertiesProvider);
    final isMobile = MediaQuery.sizeOf(context).width < 700;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 80,
        actions: [
          if (session.value?.role == 'tenant')
            PopupMenuButton<AccountService>(
              tooltip: 'Boarder services',
              icon: const Icon(Icons.dashboard_outlined),
              onSelected: (service) => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => AccountServicePage(service: service)),
              ),
              itemBuilder: (_) => [
                for (final service in AccountService.values.where((item) => item != AccountService.proofs))
                  PopupMenuItem(value: service, child: Text(service.title)),
              ],
            ),
          if (session.value?.role == 'tenant')
            IconButton(
              tooltip: 'My reservations',
              onPressed: () => context.push('/my-reservations'),
              icon: const Icon(Icons.event_note_outlined),
            ),
          IconButton(
            tooltip: 'Sign in or register',
            onPressed: () => context.push('/account'),
            icon: const Icon(Icons.account_circle_outlined),
          ),
          const SizedBox(width: 12),
        ],
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        titleSpacing: isMobile ? 20 : 40,
        title: const Row(
          children: [
            Icon(Icons.home_work_rounded, color: blue, size: 30),
            SizedBox(width: 10),
            Text(
              'BoardEase',
              style: TextStyle(
                color: navy,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.7,
              ),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(isMobile ? 20 : 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(isMobile ? 28 : 48),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [navy, Color(0xFF244579)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'A PLACE TO BELONG',
                        style: TextStyle(
                          color: Color(0xFF5EEAD4),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Find your next\nplace to call home.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isMobile ? 34 : 52,
                          fontWeight: FontWeight.w800,
                          height: 1.12,
                          letterSpacing: -1.5,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'Explore boarding houses and find a location '
                        'that fits your everyday life.',
                        style: TextStyle(
                          color: Color(0xFFCBD5E1),
                          fontSize: 16,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        onChanged: (value) {
                          setState(() => search = value.trim());
                        },
                        decoration: const InputDecoration(
                          hintText: 'Search property name or address',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 36),
                const Text(
                  'Explore properties',
                  style: TextStyle(
                    fontSize: 26,
                    color: navy,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your next chapter starts with the right place.',
                  style: TextStyle(color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 24),
                properties.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(48),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (error, stack) => Center(
                    child: Column(
                      children: [
                        const Text('Could not load properties.'),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () {
                            ref.invalidate(propertiesProvider);
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                  data: (items) {
                    if (apiBaseUrl.isEmpty) {
                      return const StatusCard(
                        icon: Icons.settings_ethernet_rounded,
                        title: 'Property connection pending',
                        message:
                            'The backend API needs to be configured '
                            'before property listings can load.',
                      );
                    }

                    final query = search.toLowerCase();
                    final filtered = items.where((property) {
                      final text =
                          '${property['property_name'] ?? ''} '
                          '${property['address'] ?? ''}';
                      return text.toLowerCase().contains(query);
                    }).toList();

                    if (filtered.isEmpty) {
                      return StatusCard(
                        icon: Icons.home_work_outlined,
                        title: query.isEmpty
                            ? 'No properties published yet'
                            : 'No matching properties',
                        message: query.isEmpty
                            ? 'Published properties will appear here.'
                            : 'Try another property name or address.',
                      );
                    }

                    return Column(
                      children: filtered.map((property) {
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ListTile(
                            contentPadding: const EdgeInsets.all(20),
                            leading: const Icon(
                              Icons.apartment_rounded,
                              color: blue,
                              size: 32,
                            ),
                            title: Text(
                              '${property['property_name'] ?? ''}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text('${property['address'] ?? ''}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => context.push('/properties/${property['property_id']}'),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          Icon(icon, color: blue, size: 42),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              color: navy,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF64748B), height: 1.5),
          ),
        ],
      ),
    );
  }
}
