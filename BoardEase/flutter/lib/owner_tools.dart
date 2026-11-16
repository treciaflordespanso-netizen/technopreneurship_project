import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'session.dart';

Future<dynamic> ownerRequest(
  String path, {
  String method = 'GET',
  Map<String, String>? fields,
}) async {
  const configured = String.fromEnvironment('API_BASE_URL');
  final base = configured.replaceFirst(RegExp(r'/+$'), '');
  final active = session.value;
  if (active == null) throw StateError('Please sign in again.');
  final uri = Uri.parse('$base$path');
  final headers = {
    'Authorization': 'Bearer ${active.token}',
    'Content-Type': 'application/json',
  };
  final body = fields == null ? null : jsonEncode(fields);
  final response = await (switch (method) {
    'POST' => http.post(uri, headers: headers, body: body),
    'PUT' => http.put(uri, headers: headers, body: body),
    _ => http.get(uri, headers: headers),
  }).timeout(const Duration(seconds: 15));
  final data = jsonDecode(utf8.decode(response.bodyBytes));
  if (response.statusCode >= 200 && response.statusCode < 300) return data;
  final detail = data is Map ? data['detail'] : null;
  throw StateError(detail is String ? detail : 'Request failed (${response.statusCode}).');
}

String ownerRequestError(Object error) => error is StateError
    ? error.message
    : 'Could not complete the request. Check the API and retry.';

List<Map<String, dynamic>> _rows(dynamic data) =>
    (data as List<dynamic>).cast<Map<String, dynamic>>();

enum OwnerReport {
  summary('Dashboard Summary', '/owner/summary'),
  activity('Activity Log', '/owner/activity'),
  reminders('Rent Reminders', '/owner/rent-reminders'),
  subscriptions('Subscriptions', '/owner/subscriptions');

  const OwnerReport(this.title, this.path);
  final String title;
  final String path;
}

class OwnerReportPage extends StatefulWidget {
  const OwnerReportPage({super.key, required this.report});
  final OwnerReport report;

  @override
  State<OwnerReportPage> createState() => _OwnerReportPageState();
}

class _OwnerReportPageState extends State<OwnerReportPage> {
  late Future<dynamic> _request = ownerRequest(widget.report.path);

  List<Widget> _items(dynamic data) {
    switch (widget.report) {
      case OwnerReport.summary:
        final labels = {
          'properties': 'Properties', 'rooms': 'Rooms', 'capacity': 'Total spaces',
          'tenants': 'Active assigned tenants', 'pending_reservations': 'Pending reservations',
          'open_maintenance': 'Open maintenance', 'unpaid_bills': 'Unpaid bills',
          'payments_received': 'Payments received',
        };
        return [
          for (final entry in labels.entries)
            ListTile(
              title: Text(entry.value),
              trailing: Text("${entry.key == 'payments_received' ? '₱' : ''}${data[entry.key]}"),
            ),
        ];
      case OwnerReport.activity:
        return [
          for (final row in _rows(data))
            ListTile(
              title: Text('${row['action']}'),
              subtitle: Text('${row['created_at'] ?? ''}'),
            ),
        ];
      case OwnerReport.reminders:
        return [
          for (final row in _rows(data))
            ListTile(
              title: Text('${row['full_name']} · Bill #${row['bill_id']}'),
              subtitle: Text(
                '${row['property_name']} · Room ${row['room_number']}\n'
                '${row['overdue'] == true ? 'Overdue' : 'Due'}: ${row['due_date']}',
              ),
              trailing: Text('₱${row['remaining_balance']}'),
            ),
        ];
      case OwnerReport.subscriptions:
        final plans = _rows(data['plans']);
        final subscriptions = _rows(data['subscriptions']);
        return [
          const ListTile(title: Text('Your subscriptions')),
          if (subscriptions.isEmpty)
            const ListTile(subtitle: Text('No subscriptions yet.')),
          for (final row in subscriptions)
            ListTile(
              title: Text('${row['plan_name'] ?? 'Subscription'}'),
              subtitle: Text(
                '${row['start_date']} to ${row['end_date']}\n'
                '${row['subscription_status']} · Payment: ${row['payment_status']}',
              ),
            ),
          const ListTile(title: Text('Available plans')),
          if (plans.isEmpty)
            const ListTile(subtitle: Text('No active plans.')),
          for (final row in plans)
            ListTile(
              title: Text('${row['plan_name']}'),
              subtitle: Text(
                '₱${row['price']} · ${row['duration_days']} days'
                '${row['property_limit'] == null ? '' : ' · ${row['property_limit']} properties'}',
              ),
            ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.report.title),
      actions: [
        if (widget.report == OwnerReport.reminders)
          TextButton(
            child: const Text('Send in-app reminders'),
            onPressed: () async {
              try {
                final result = await ownerRequest('/owner/rent-reminders/run', method: 'POST');
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("${result['created']} new reminders.")),
                );
              } catch (error) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(ownerRequestError(error))),
                );
              }
            },
          ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: () => setState(() {
            _request = ownerRequest(widget.report.path);
          }),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<dynamic>(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text(ownerRequestError(snapshot.error!)));
        }
        final items = _items(snapshot.data);
        return items.isEmpty
            ? const Center(child: Text('No records yet.'))
            : ListView(padding: const EdgeInsets.all(16), children: items);
      },
    ),
  );
}

class OwnerMaintenancePage extends StatefulWidget {
  const OwnerMaintenancePage({
    super.key,
    required this.propertyId,
    required this.roomId,
    required this.roomNumber,
  });
  final int propertyId;
  final int roomId;
  final String roomNumber;

  @override
  State<OwnerMaintenancePage> createState() => _OwnerMaintenancePageState();
}

class _OwnerMaintenancePageState extends State<OwnerMaintenancePage> {
  String get _path =>
      '/owner/properties/${widget.propertyId}/rooms/${widget.roomId}/maintenance';
  late Future<dynamic> _request = ownerRequest(_path);
  bool _busy = false;

  Future<void> _save(String path, String method, Map<String, String> fields) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ownerRequest(path, method: method, fields: fields);
      if (!mounted) return;
      setState(() { _request = ownerRequest(_path); });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ownerRequestError(error))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _MaintenanceForm(),
    );
    if (mounted && fields != null) await _save(_path, 'POST', fields);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Room ${widget.roomNumber} maintenance'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: _busy ? null : () => setState(() {
            _request = ownerRequest(_path);
          }),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: _busy ? null : _add,
      tooltip: 'Add maintenance request',
      child: const Icon(Icons.add),
    ),
    body: FutureBuilder<dynamic>(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text(ownerRequestError(snapshot.error!)));
        }
        final requests = _rows(snapshot.data);
        if (requests.isEmpty) {
          return const Center(child: Text('No maintenance requests yet.'));
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
          children: [
            for (final row in requests)
              ListTile(
                title: Text('${row['issue_title']}'),
                subtitle: Text(
                  "${row['issue_description']}\n"
                  "${row['priority']} · ${row['request_status']}",
                ),
                trailing: switch (row['request_status']) {
                  'pending' => TextButton(
                    onPressed: _busy ? null : () => _save(
                      "/owner/maintenance/${row['request_id']}/status",
                      'PUT',
                      {'status': 'in_progress'},
                    ),
                    child: const Text('Start'),
                  ),
                  'in_progress' => TextButton(
                    onPressed: _busy ? null : () => _save(
                      "/owner/maintenance/${row['request_id']}/status",
                      'PUT',
                      {'status': 'resolved'},
                    ),
                    child: const Text('Resolve'),
                  ),
                  _ => null,
                },
              ),
          ],
        );
      },
    ),
  );
}

class _MaintenanceForm extends StatefulWidget {
  const _MaintenanceForm();

  @override
  State<_MaintenanceForm> createState() => _MaintenanceFormState();
}

class _MaintenanceFormState extends State<_MaintenanceForm> {
  final _form = GlobalKey<FormState>();
  var _title = '';
  var _description = '';
  var _urgent = false;

  String? _required(String? value) =>
      (value ?? '').trim().isEmpty ? 'Required' : null;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add maintenance request'),
    scrollable: true,
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            decoration: const InputDecoration(labelText: 'Title'),
            maxLength: 150,
            validator: _required,
            onChanged: (value) => _title = value,
          ),
          TextFormField(
            decoration: const InputDecoration(labelText: 'Description'),
            maxLength: 3000,
            maxLines: 3,
            validator: _required,
            onChanged: (value) => _description = value,
          ),
          SwitchListTile(
            title: const Text('Urgent'),
            value: _urgent,
            onChanged: (value) => setState(() => _urgent = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState?.validate() != true) return;
          Navigator.of(context).pop({
            'title': _title.trim(),
            'description': _description.trim(),
            'priority': _urgent ? 'urgent' : 'normal',
          });
        },
        child: const Text('Save'),
      ),
    ],
  );
}
