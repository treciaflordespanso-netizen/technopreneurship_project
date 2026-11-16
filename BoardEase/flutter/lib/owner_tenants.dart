import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'session.dart';

class OwnerTenantsPage extends StatefulWidget {
  const OwnerTenantsPage({
    super.key,
    required this.propertyId,
    required this.roomId,
    required this.roomNumber,
  });

  final int propertyId;
  final int roomId;
  final String roomNumber;

  @override
  State<OwnerTenantsPage> createState() => _OwnerTenantsPageState();
}

class _OwnerTenantsPageState extends State<OwnerTenantsPage> {
  static const _api = String.fromEnvironment('API_BASE_URL');
  static const _timeout = Duration(seconds: 15);

  late Future<List<Map<String, dynamic>>> _tenants;
  bool _reservationInProgress = false;

  Uri get _url => Uri.parse(
    '${_api.replaceFirst(RegExp(r'/+$'), '')}'
    '/owner/properties/${widget.propertyId}'
    '/rooms/${widget.roomId}/tenants',
  );

  Map<String, String> get _headers {
    final active = session.value;
    if (active == null) throw StateError('Please sign in again.');

    return {
      'Authorization': 'Bearer ${active.token}',
      'Content-Type': 'application/json',
    };
  }

  @override
  void initState() {
    super.initState();
    _tenants = _loadTenants();
  }

  void _checkResponse(http.Response response, int expected) {
    if (response.statusCode == expected) return;

    var message = 'Request failed (HTTP ${response.statusCode}).';
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map && body['detail'] is String) {
        message = body['detail'] as String;
      }
    } on FormatException {
      // Keep the HTTP status for plain-text errors.
    }

    if (response.statusCode >= 500) throw Exception(message);
    throw StateError(message);
  }

  Future<List<Map<String, dynamic>>> _loadTenants() async {
    final response = await http.get(_url, headers: _headers).timeout(_timeout);
    _checkResponse(response, 200);

    final rows = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    return rows.cast<Map<String, dynamic>>();
  }

  void _refresh() {
    final tenants = _loadTenants();
    setState(() {
      _tenants = tenants;
    });
  }

  Future<void> _viewReservations(Map<String, dynamic> tenant) async {
    try {
      while (mounted) {
        final response = await http
            .get(
              Uri.parse('$_url/${tenant['tenant_id']}/reservations'),
              headers: _headers,
            )
            .timeout(_timeout);
        _checkResponse(response, 200);
        final reservations = (jsonDecode(utf8.decode(response.bodyBytes)) as List)
            .cast<Map<String, dynamic>>();

        if (!mounted) return;
        final decision = await showDialog<(int, String)>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Reservations'),
            scrollable: true,
            content: SizedBox(
              width: 360,
              child: reservations.isEmpty
                  ? const Text('No reservations yet.')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final reservation in reservations)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              'Reservation #${reservation['reservation_id']}',
                            ),
                            subtitle: Text(
                              'Preferred move-in: '
                              "${reservation['preferred_move_in_date'] ?? 'Not set'}\n"
                              "Status: ${reservation['reservation_status'] ?? 'Unknown'}",
                            ),
                            trailing: reservation['reservation_status'] == 'pending'
                                ? PopupMenuButton<String>(
                                    tooltip: 'Update reservation status',
                                    onSelected: (status) => Navigator.of(dialogContext)
                                        .pop((reservation['reservation_id'] as int, status)),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(value: 'approved', child: Text('Approve')),
                                      PopupMenuItem(value: 'rejected', child: Text('Reject')),
                                      PopupMenuItem(value: 'cancelled', child: Text('Cancel reservation')),
                                    ],
                                  )
                                : null,
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        if (!mounted || decision == null) return;
        final (reservationId, status) = decision;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Update reservation #$reservationId?'),
            content: Text('Set status to $status.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Back'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Confirm'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (confirmed == true) {
          final base = _api.replaceFirst(RegExp(r'/+$'), '');
          final update = await http
              .put(
                Uri.parse('$base/owner/reservations/$reservationId/status'),
                headers: _headers,
                body: jsonEncode({'status': status}),
              )
              .timeout(_timeout);
          _checkResponse(update, 200);
        }
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StateError
                ? error.message
                : 'Could not load reservations. Check the API and try again.',
          ),
        ),
      );
    }
  }

  Future<void> _createReservation(Map<String, dynamic> tenant) async {
    if (_reservationInProgress) return;
    _reservationInProgress = true;

    try {
      final today = DateUtils.dateOnly(DateTime.now());
      final moveIn = await showDatePicker(
        context: context,
        initialDate: today,
        firstDate: today,
        lastDate: DateTime(today.year + 5, 12, 31),
        helpText: 'Choose preferred move-in date',
      );
      if (!mounted || moveIn == null) return;

      final date = moveIn.toIso8601String().split('T').first;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Create Reservation'),
          content: Text(
            '${tenant['full_name']}\n'
            'Room ${widget.roomNumber}\n'
            'Preferred move-in: $date',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save reservation'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;

      final response = await http
          .post(
            Uri.parse('$_url/${tenant['tenant_id']}/reservations'),
            headers: _headers,
            body: jsonEncode({'preferred_move_in_date': date}),
          )
          .timeout(_timeout);
      _checkResponse(response, 201);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reservation saved as pending.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StateError
                ? error.message
                : 'Could not confirm the save. Check the API before retrying.',
          ),
        ),
      );
    } finally {
      _reservationInProgress = false;
    }
  }

  Future<void> _openForm({
    Map<String, dynamic>? tenant,
    bool agreement = false,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TenantDialog(
        tenant: tenant,
        agreement: agreement,
        onSave: (fields) async {
          final headers = _headers;
          final body = jsonEncode(fields);
          final http.Response response;
          final int expected;

          if (agreement) {
            final uri = Uri.parse('$_url/${tenant!['tenant_id']}/agreements');
            response = await http
                .post(uri, headers: headers, body: body)
                .timeout(_timeout);
            expected = 201;
          } else if (tenant == null) {
            response = await http
                .post(_url, headers: headers, body: body)
                .timeout(_timeout);
            expected = 201;
          } else {
            final uri = Uri.parse('$_url/${tenant['tenant_id']}');
            response = await http
                .put(uri, headers: headers, body: body)
                .timeout(_timeout);
            expected = 200;
          }

          _checkResponse(response, expected);
        },
      ),
    );

    if (!mounted) return;
    if (!agreement) _refresh();
    if (saved != true) return;

    final String message;
    if (agreement) {
      message = 'Rental agreement created as pending.';
    } else {
      message = tenant == null ? 'Tenant added.' : 'Tenant updated.';
    }

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showPaymentHistory(
    BuildContext context,
    Map<String, dynamic> bill,
  ) async {
    final payments =
        (bill['payment_history'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList();

    await showDialog<void>(
      context: context,
      builder: (historyContext) => AlertDialog(
        title: Text('Payment History · Bill #${bill['bill_id']}'),
        scrollable: true,
        content: SizedBox(
          width: 360,
          child: payments.isEmpty
              ? const Text('No payments recorded yet.')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final payment in payments)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('₱${payment['amount_paid']}'),
                        subtitle: Text(
                          '${switch (payment['payment_method']) {
                            'cash' => 'Cash',
                            'gcash' => 'GCash',
                            'bank_transfer' => 'Bank transfer',
                            final method => method?.toString() ?? 'Unknown method',
                          }}\n'
                          '${payment['payment_date']?.toString().replaceFirst('T', ' ') ?? 'Date unavailable'}',
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(historyContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }


  Future<void> _viewRentBills(Map<String, dynamic> tenant) async {
    try {
      while (mounted) {
        final response = await http
            .get(
              Uri.parse('$_url/${tenant['tenant_id']}/bills'),
              headers: _headers,
            )
            .timeout(_timeout);
        _checkResponse(response, 200);

        final bills = (jsonDecode(utf8.decode(response.bodyBytes)) as List)
            .cast<Map<String, dynamic>>();

        if (!mounted) return;

        final selected = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Rent Bills'),
            scrollable: true,
            content: SizedBox(
              width: 360,
              child: bills.isEmpty
                  ? const Text('No rent bills yet.')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final bill in bills)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              'Bill #${bill['bill_id']} · ₱${bill['amount_due']}',
                            ),
                            subtitle: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Agreement #${bill['agreement_id']}\n'
                                  'Billing period: ${bill['billing_period']}\n'
                                  'Due: ${bill['due_date']}\n'
                                  'Balance: ₱${bill['remaining_balance']}\n'
                                  'Status: ${bill['bill_status']}',
                                ),
                                TextButton(
                                  onPressed: () =>
                                      _showPaymentHistory(dialogContext, bill),
                                  child: const Text('Payment History'),
                                ),
                              ],
                            ),
                            trailing:
                                bill['bill_status'] == 'unpaid' &&
                                    (num.tryParse(
                                              '${bill['remaining_balance']}',
                                            ) ??
                                            0) >
                                        0
                                ? TextButton(
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(bill),
                                    child: const Text('Record Payment'),
                                  )
                                : null,
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        if (!mounted || selected == null) return;

        final saved = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _RecordPaymentDialog(
            balance: '${selected['remaining_balance']}',
            onSave: (amount, method) async {
              final api = _api.replaceFirst(RegExp(r'/+$'), '');
              final uri = Uri.parse(
                '$api/owner/bills/${selected['bill_id']}/payments',
              );
              final response = await http
                  .post(
                    uri,
                    headers: _headers,
                    body: jsonEncode({
                      'amount_paid': amount,
                      'expected_balance': selected['remaining_balance'],
                      'payment_method': method,
                    }),
                  )
                  .timeout(_timeout);
              _checkResponse(response, 201);
            },
          ),
        );
        if (!mounted) return;
        if (saved == true) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Payment recorded.')));
        }
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StateError
                ? error.message
                : 'Could not load rent bills. Check the API and try again.',
          ),
        ),
      );
    }
  }

  Future<void> _openRentBill(Map<String, dynamic> tenant) async {
    try {
      final response = await http
          .get(
            Uri.parse('$_url/${tenant['tenant_id']}/agreements'),
            headers: _headers,
          )
          .timeout(_timeout);
      _checkResponse(response, 200);

      final rows = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      final agreements = rows.cast<Map<String, dynamic>>().where((row) {
        return row['agreement_status'] == 'pending' ||
            row['agreement_status'] == 'active';
      }).toList();

      if (!mounted) return;
      if (agreements.isEmpty) {
        throw StateError('This tenant has no pending or active agreement.');
      }

      final bill = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _RentBillDialog(
          agreements: agreements,
          onSave: (agreementId, month, dueDate) async {
            final api = _api.replaceFirst(RegExp(r'/+$'), '');
            final result = await http
                .post(
                  Uri.parse('$api/owner/agreements/$agreementId/bills'),
                  headers: _headers,
                  body: jsonEncode({
                    'billing_period': month,
                    'due_date': dueDate,
                  }),
                )
                .timeout(_timeout);
            _checkResponse(result, 201);
            return jsonDecode(utf8.decode(result.bodyBytes))
                as Map<String, dynamic>;
          },
        ),
      );

      if (!mounted || bill == null) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Rent bill #${bill['bill_id']} created'),
          content: Text(
            'Amount due: ₱${bill['amount_due']}\n'
            'Billing period: ${bill['billing_period']}\n'
            'Due date: ${bill['due_date']}\n'
            'Status: ${bill['bill_status']}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StateError
                ? error.message
                : 'Could not load rental agreements.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Room ${widget.roomNumber} tenants')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('Add Tenant'),
            ),
          ),
          const SizedBox(height: 16),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _tenants,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator();
              }

              if (snapshot.hasError) {
                final error = snapshot.error;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      error is StateError
                          ? error.message
                          : 'Could not load tenants.',
                    ),
                    TextButton(onPressed: _refresh, child: const Text('Retry')),
                  ],
                );
              }

              final tenants = snapshot.data ?? [];
              if (tenants.isEmpty) return const Text('No tenants yet.');

              return Column(
                children: [
                  for (final tenant in tenants)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(tenant['full_name'] as String),
                      subtitle: Text(
                        [
                          tenant['email'],
                          tenant['phone_number'],
                        ].whereType<String>().join(' • '),
                      ),
                      onTap: () => _openForm(tenant: tenant),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Tenant actions',
                        onSelected: (action) {
                          if (action == 'view_bills') {
                            _viewRentBills(tenant);
                          } else if (action == 'view_reservations') {
                            _viewReservations(tenant);
                          } else if (action == 'reservation') {
                            _createReservation(tenant);
                          } else if (action == 'bill') {
                            _openRentBill(tenant);
                          } else {
                            _openForm(
                              tenant: tenant,
                              agreement: action == 'agreement',
                            );
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text('Edit Tenant'),
                          ),
                          PopupMenuItem(
                            value: 'agreement',
                            child: Text('Create Agreement'),
                          ),
                          PopupMenuItem(
                            value: 'reservation',
                            child: Text('Create Reservation'),
                          ),
                          PopupMenuItem(
                            value: 'view_reservations',
                            child: Text('View Reservations'),
                          ),
                          PopupMenuItem(
                            value: 'bill',
                            child: Text('Create Rent Bill'),
                          ),
                          PopupMenuItem(
                            value: 'view_bills',
                            child: Text('View Rent Bills'),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _TenantDialog extends StatefulWidget {
  const _TenantDialog({
    required this.tenant,
    required this.agreement,
    required this.onSave,
  });

  final Map<String, dynamic>? tenant;
  final bool agreement;
  final Future<void> Function(Map<String, dynamic>) onSave;

  @override
  State<_TenantDialog> createState() => _TenantDialogState();
}

class _TenantDialogState extends State<_TenantDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  final _deposit = TextEditingController();

  DateTime? _start;
  DateTime? _end;
  bool _saving = false;
  bool _unconfirmed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final tenant = widget.tenant;
    _name = TextEditingController(text: tenant?['full_name'] as String?);
    _email = TextEditingController(text: tenant?['email'] as String?);
    _phone = TextEditingController(text: tenant?['phone_number'] as String?);
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _deposit.dispose();
    super.dispose();
  }

  String _dateText(DateTime date) => date.toIso8601String().split('T').first;

  Future<void> _pickDate({required bool start}) async {
    final earliest = start ? DateTime(1900) : (_start ?? DateTime(1900));
    final current = (start ? _start : _end) ?? _start ?? DateTime.now();

    final chosen = await showDatePicker(
      context: context,
      firstDate: earliest,
      lastDate: DateTime(2100, 12, 31),
      initialDate: current.isBefore(earliest) ? earliest : current,
    );

    if (!mounted || chosen == null) return;
    setState(() {
      if (start) {
        _start = chosen;
        if (_end?.isBefore(chosen) ?? false) _end = null;
      } else {
        _end = chosen;
      }
    });
  }

  Future<void> _submit() async {
    if (_saving || _unconfirmed || !_formKey.currentState!.validate()) return;

    final start = _start;
    final end = _end;
    if (widget.agreement && start == null) {
      setState(() {
        _error = 'Select a start date.';
      });
      return;
    }

    final deposit = _deposit.text.trim();
    final fields = widget.agreement
        ? <String, dynamic>{
            'start_date': _dateText(start!),
            'end_date': end == null ? null : _dateText(end),
            'security_deposit': deposit.isEmpty ? '0' : deposit,
          }
        : <String, dynamic>{
            'full_name': _name.text.trim(),
            'email': _email.text.trim(),
            'phone_number': _phone.text.trim(),
          };

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.onSave(fields);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _unconfirmed = error is! StateError;
        _error = error is StateError
            ? error.message
            : 'Save could not be confirmed. Check before retrying.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.tenant != null;
    final title = widget.agreement
        ? 'Create Agreement'
        : (editing ? 'Edit Tenant' : 'Add Tenant');
    final saveLabel = widget.agreement
        ? 'Create agreement'
        : (editing ? 'Save changes' : 'Save tenant');

    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(title),
        scrollable: true,
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.agreement) ...[
                Text(_name.text),
                const Text('Monthly rent is taken from the room rate.'),
                ListTile(
                  title: const Text('Start date'),
                  subtitle: Text(
                    _start == null ? 'Select date' : _dateText(_start!),
                  ),
                  trailing: const Icon(Icons.calendar_today_outlined),
                  onTap: _saving ? null : () => _pickDate(start: true),
                ),
                ListTile(
                  title: const Text('End date (optional)'),
                  subtitle: Text(
                    _end == null ? 'Open-ended' : _dateText(_end!),
                  ),
                  trailing: _end == null
                      ? const Icon(Icons.calendar_today_outlined)
                      : IconButton(
                          tooltip: 'Clear end date',
                          icon: const Icon(Icons.clear),
                          onPressed: _saving
                              ? null
                              : () => setState(() {
                                  _end = null;
                                }),
                        ),
                  onTap: _saving ? null : () => _pickDate(start: false),
                ),
                TextFormField(
                  controller: _deposit,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Security deposit (₱, optional)',
                  ),
                  validator: (value) {
                    final amount = (value ?? '').trim();
                    if (amount.isEmpty ||
                        RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(amount)) {
                      return null;
                    }
                    return 'Enter a valid amount, e.g. 1100.00';
                  },
                ),
              ] else ...[
                TextFormField(
                  controller: _name,
                  enabled: !_saving,
                  maxLength: 150,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'Enter the full name'
                      : null,
                ),
                TextFormField(
                  controller: _email,
                  enabled: !_saving,
                  maxLength: 150,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email (optional)',
                  ),
                ),
                TextFormField(
                  controller: _phone,
                  enabled: !_saving,
                  maxLength: 20,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone (optional)',
                  ),
                ),
              ],
              if (_error != null) Text(_error!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(_unconfirmed ? 'Close' : 'Cancel'),
          ),
          FilledButton(
            onPressed: _saving || _unconfirmed ? null : _submit,
            child: Text(_saving ? 'Saving…' : saveLabel),
          ),
        ],
      ),
    );
  }
}

class _RentBillDialog extends StatefulWidget {
  const _RentBillDialog({required this.agreements, required this.onSave});

  final List<Map<String, dynamic>> agreements;
  final Future<Map<String, dynamic>> Function(int, String, String) onSave;

  @override
  State<_RentBillDialog> createState() => _RentBillDialogState();
}

class _RentBillDialogState extends State<_RentBillDialog> {
  int _selection = 0;
  DateTime? _month;
  DateTime? _dueDate;
  bool _saving = false;
  bool _unconfirmed = false;
  String? _error;

  Map<String, dynamic> get _agreement => widget.agreements[_selection];

  String _date(DateTime day) => day.toIso8601String().split('T').first;

  Future<void> _pickDate({required bool billingMonth}) async {
    final start = DateTime.parse(_agreement['start_date'] as String);
    final endText = _agreement['end_date'] as String?;
    final end = endText == null ? null : DateTime.parse(endText);
    final first = billingMonth
        ? DateTime(start.year, start.month)
        : DateTime(1900);
    final last = billingMonth && end != null
        ? DateTime(end.year, end.month + 1, 0)
        : DateTime(2100, 12, 31);
    var initial = (billingMonth ? _month : _dueDate) ?? DateTime.now();
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final selected = await showDatePicker(
      context: context,
      firstDate: first,
      lastDate: last,
      initialDate: initial,
    );
    if (!mounted || selected == null) return;
    setState(() {
      if (billingMonth) {
        _month = DateTime(selected.year, selected.month);
      } else {
        _dueDate = selected;
      }
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_saving || _unconfirmed) return;
    final month = _month;
    final dueDate = _dueDate;
    if (month == null || dueDate == null) {
      setState(() {
        _error = 'Select the billing month and due date.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final bill = await widget.onSave(
        _agreement['agreement_id'] as int,
        _date(month),
        _date(dueDate),
      );
      if (mounted) Navigator.of(context).pop(bill);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _unconfirmed = error is! StateError;
        _error = error is StateError
            ? error.message
            : 'Save could not be confirmed. Check your bills before retrying.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Create Rent Bill'),
        scrollable: true,
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Rental agreement'),
              DropdownButton<int>(
                isExpanded: true,
                value: _selection,
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() {
                          _selection = value;
                          _month = null;
                          _error = null;
                        });
                      },
                items: [
                  for (var i = 0; i < widget.agreements.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '#${widget.agreements[i]['agreement_id']} • '
                        '${widget.agreements[i]['start_date']} to '
                        "${widget.agreements[i]['end_date'] ?? 'open-ended'}",
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
              Text('Amount due: ₱${_agreement['monthly_rent']}'),
              ListTile(
                title: const Text('Billing month'),
                subtitle: Text(
                  _month == null
                      ? 'Pick any date in the month'
                      : _date(_month!).substring(0, 7),
                ),
                onTap: _saving ? null : () => _pickDate(billingMonth: true),
              ),
              ListTile(
                title: const Text('Due date'),
                subtitle: Text(
                  _dueDate == null ? 'Select date' : _date(_dueDate!),
                ),
                onTap: _saving ? null : () => _pickDate(billingMonth: false),
              ),
              if (_error != null) Text(_error!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(_unconfirmed ? 'Close' : 'Cancel'),
          ),
          FilledButton(
            onPressed: _saving || _unconfirmed ? null : _submit,
            child: Text(_saving ? 'Saving…' : 'Create bill'),
          ),
        ],
      ),
    );
  }
}

class _RecordPaymentDialog extends StatefulWidget {
  const _RecordPaymentDialog({required this.balance, required this.onSave});

  final String balance;
  final Future<void> Function(String amount, String method) onSave;

  @override
  State<_RecordPaymentDialog> createState() => _RecordPaymentDialogState();
}

class _RecordPaymentDialogState extends State<_RecordPaymentDialog> {
  String _amount = '';
  String _method = 'cash';
  bool _saving = false;
  bool _unconfirmed = false;
  String? _error;

  Future<void> _submit() async {
    if (_saving || _unconfirmed) return;

    final amount = _amount.trim();
    final amountValue = num.tryParse(amount);
    final balance = num.tryParse(widget.balance);

    if (!RegExp(r'^\d{1,8}(\.\d{1,2})?$').hasMatch(amount) ||
        amountValue == null ||
        amountValue <= 0 ||
        balance == null ||
        amountValue > balance) {
      setState(() {
        _error =
            'Enter a positive amount within the balance (up to 2 decimals).';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.onSave(amount, _method);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _unconfirmed = error is! StateError;
        _error = error is StateError ? error.message : 'Payment could not be confirmed. Close this form to refresh the bills.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Record Payment'),
        scrollable: true,
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Remaining balance: ₱${widget.balance}'),
              TextField(
                enabled: !_saving && !_unconfirmed,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Amount received'),
                onChanged: (value) => _amount = value,
              ),
              const Text('Payment method'),
              DropdownButton<String>(
                value: _method,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('Cash')),
                  DropdownMenuItem(value: 'gcash', child: Text('GCash')),
                  DropdownMenuItem(
                    value: 'bank_transfer',
                    child: Text('Bank transfer'),
                  ),
                ],
                onChanged: _saving || _unconfirmed
                    ? null
                    : (value) {
                        if (value != null) setState(() => _method = value);
                      },
              ),
              if (_error != null) Text(_error!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(_unconfirmed ? 'Close' : 'Cancel'),
          ),
          FilledButton(
            onPressed: _saving || _unconfirmed ? null : _submit,
            child: Text(_saving ? 'Saving…' : 'Save payment'),
          ),
        ],
      ),
    );
  }
}
