import 'session.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  static const api = String.fromEnvironment('API_BASE_URL');

  final formKey = GlobalKey<FormState>();
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool registering = false;
  bool busy = false;
  bool hidePassword = true;
  String role = 'tenant';
  String? message;
  String? token;
  Map<String, dynamic>? user;

  @override
  void initState() {
    super.initState();
    if (session.value != null) _restoreProfile();
  }

  Future<void> _restoreProfile() async {
    final active = session.value;
    if (active == null) return;
    setState(() => busy = true);
    try {
      final response = await http.get(Uri.parse('$api/auth/me'), headers: {
        'Authorization': 'Bearer ${active.token}',
      }).timeout(const Duration(seconds: 15));
      if (!mounted || session.value != active) return;
      if (response.statusCode == 401) {
        session.value = null;
        setState(() => message = 'Session expired. Please sign in again.');
        return;
      }
      if (response.statusCode != 200) throw StateError('Profile unavailable.');
      final profile = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      setState(() {
        token = active.token;
        user = profile;
      });
    } catch (_) {
      if (mounted) setState(() => message = 'Could not load your profile.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (api.isEmpty) {
      throw Exception('API connection is not configured.');
    }

    final response = await http
        .post(
          Uri.parse('$api/$path'),
          headers: {
            'Content-Type': 'application/json',
            if (session.value case final active?)
              'Authorization': 'Bearer ${active.token}',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected server response.');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(decoded['error'] ?? decoded['detail'] ?? 'Request failed.');
    }

    return decoded;
  }

  Future<void> submit() async {
    if (!formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      message = null;
    });

    try {
      final result = await post(registering ? 'auth/register' : 'auth/login', {
        'email': emailController.text.trim(),
        'password': passwordController.text,
        if (registering) ...{
          'full_name': nameController.text.trim(),
          'role': role,
        },
      });

      if (!mounted) return;

      setState(() {
        if (registering) {
          registering = false;
          message = 'Account created. Sign in to continue.';
        } else {
          token = result['token'] as String;
          user = Map<String, dynamic>.from(result['user'] as Map);
          session.value = (token: token!, role: user!['role'] as String);
        }
        passwordController.clear();
      });

      if (result.containsKey('token')) {
        context.go(result['user']['role'] == 'owner' ? '/owner' : '/');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        message = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> logout() async {
    setState(() {
      busy = true;
      message = null;
    });

    try {
      await post('auth/logout', {});
      if (!mounted) return;

      setState(() {
        session.value = null;
        token = null;
        user = null;
        message = 'You have been logged out.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        message = 'Could not log out. Please try again.';
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xFF14213D);
    const blue = Color(0xFF2563EB);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('BoardEase'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              color: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: user != null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.check_circle_outline,
                            size: 56,
                            color: blue,
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'Welcome, ${user!['full_name']}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: navy,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text('${user!['email']}'),
                          const SizedBox(height: 8),
                          Chip(label: Text('${user!['role']}')),
                          const SizedBox(height: 16),
                          const Text(
                            'You are signed in.',
                            textAlign: TextAlign.center,
                          ),
                          if (message != null) ...[
                            const SizedBox(height: 16),
                            Text(message!),
                          ],
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: busy ? null : logout,
                            icon: const Icon(Icons.logout),
                            label: Text(busy ? 'Signing out...' : 'Sign out'),
                          ),
                        ],
                      )
                    : Form(
                        key: formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Icon(
                              Icons.home_work_rounded,
                              size: 44,
                              color: blue,
                            ),
                            const SizedBox(height: 20),
                            Text(
                              registering
                                  ? 'Create your account'
                                  : 'Welcome back',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color: navy,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              registering
                                  ? 'Start your BoardEase journey.'
                                  : 'Sign in to your BoardEase account.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xFF64748B)),
                            ),
                            const SizedBox(height: 28),
                            if (registering) ...[
                              TextFormField(
                                controller: nameController,
                                enabled: !busy,
                                maxLength: 150,
                                decoration: const InputDecoration(
                                  labelText: 'Full name',
                                  prefixIcon: Icon(Icons.person_outline),
                                ),
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                    ? 'Enter your full name.'
                                    : null,
                              ),
                              const SizedBox(height: 16),
                              DropdownButtonFormField<String>(
                                initialValue: role,
                                decoration: const InputDecoration(
                                  labelText: 'Account type',
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'tenant',
                                    child: Text('Tenant'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'owner',
                                    child: Text('Property owner'),
                                  ),
                                ],
                                onChanged: busy
                                    ? null
                                    : (value) {
                                        if (value != null) {
                                          setState(() => role = value);
                                        }
                                      },
                              ),
                              const SizedBox(height: 20),
                            ],
                            TextFormField(
                              controller: emailController,
                              enabled: !busy,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: 'Email address',
                                prefixIcon: Icon(Icons.email_outlined),
                              ),
                              validator: (value) {
                                final email = (value ?? '').trim();
                                if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                    .hasMatch(email)) {
                                  return 'Enter a valid email.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 20),
                            TextFormField(
                              controller: passwordController,
                              enabled: !busy,
                              obscureText: hidePassword,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                helperText: registering
                                    ? 'At least 12 characters'
                                    : null,
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  onPressed: () {
                                    setState(() {
                                      hidePassword = !hidePassword;
                                    });
                                  },
                                  icon: Icon(
                                    hidePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                ),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Enter your password.';
                                }
                                if (registering && value.length < 12) {
                                  return 'Use at least 12 characters.';
                                }
                                if (utf8.encode(value).length > 72) {
                                  return 'Your password is too long.';
                                }
                                return null;
                              },
                            ),
                            if (message != null) ...[
                              const SizedBox(height: 20),
                              Text(
                                message!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: navy),
                              ),
                            ],
                            const SizedBox(height: 24),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: blue,
                                padding: const EdgeInsets.all(18),
                              ),
                              onPressed: busy ? null : submit,
                              child: Text(
                                busy
                                    ? 'Please wait...'
                                    : registering
                                    ? 'Create account'
                                    : 'Sign in',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () {
                                      setState(() {
                                        registering = !registering;
                                        message = null;
                                        passwordController.clear();
                                        formKey.currentState?.reset();
                                      });
                                    },
                              child: Text(
                                registering
                                    ? 'Already registered? Sign in'
                                    : 'New to BoardEase? Create account',
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
