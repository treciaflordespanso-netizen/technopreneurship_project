import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'owner_tools.dart';

enum AccountService {
  bills('My Rent Bills', '/tenant/bills'),
  maintenance('My Maintenance Requests', '/tenant/maintenance'),
  notifications('Notifications', '/account/notifications'),
  proofs('Review Manual Payment Proofs', '/owner/payment-proofs');

  const AccountService(this.title, this.path);
  final String title;
  final String path;
}

class AccountServicePage extends StatefulWidget {
  const AccountServicePage({super.key, required this.service});
  final AccountService service;

  @override
  State<AccountServicePage> createState() => _AccountServicePageState();
}

class _AccountServicePageState extends State<AccountServicePage> {
  late Future<dynamic> _request = ownerRequest(widget.service.path);
  bool _busy = false;

  void _refresh() => setState(() {
    _request = ownerRequest(widget.service.path);
  });

  Future<void> _send(String path, String method, [Map<String, String>? data]) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ownerRequest(path, method: method, fields: data);
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ownerRequestError(error))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _form({int? billId}) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _RequestForm(payment: billId != null),
    );
    if (!mounted || result == null) return;
    await _send(
      billId == null ? '/tenant/maintenance' : '/tenant/bills/$billId/payment-proofs',
      'POST', result,
    );
  }

  Future<void> _openProof(String value) async {
    final uri = Uri.tryParse(value);
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.hasAuthority) {
      try {
        if (await launchUrl(uri)) return;
      } catch (_) {
        // Use the same feedback as an unsupported link.
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the proof link.')),
      );
    }
  }

  Widget _row(Map<String, dynamic> row) {
    switch (widget.service) {
      case AccountService.bills:
        final payments = (row['payments'] as List<dynamic>).cast<Map<String, dynamic>>();
        return Card(
          child: ExpansionTile(
            title: Text("Bill #${row['bill_id']} · ₱${row['remaining_balance']} due"),
            subtitle: Text(
              "${row['property_name']} · Room ${row['room_number']}\n"
              "Due ${row['due_date']} · ${row['bill_status']}",
            ),
            children: [
              if (payments.isEmpty) const ListTile(title: Text('No payments recorded.')),
              for (final payment in payments)
                ListTile(
                  title: Text("₱${payment['amount_paid']} · ${payment['payment_status']}"),
                  subtitle: Text([
                    '${payment['payment_method']}',
                    if (payment['transaction_reference'] != null)
                      "Reference ${payment['transaction_reference']}",
                    if (payment['receipt_number'] != null) "Receipt ${payment['receipt_number']}",
                  ].join(' · ')),
                ),
              if (row['bill_status'] == 'unpaid' &&
                  (num.tryParse('${row['remaining_balance']}') ?? 0) > 0)
                TextButton(
                  onPressed: _busy ? null : () => _form(billId: row['bill_id'] as int),
                  child: const Text('Submit manual payment proof'),
                ),
            ],
          ),
        );
      case AccountService.maintenance:
        return ListTile(
          title: Text('${row['issue_title']}'),
          subtitle: Text(
            "${row['issue_description']}\n${row['priority']} · ${row['request_status']}"
            "${row['admin_remarks'] == null ? '' : "\n${row['admin_remarks']}"}",
          ),
        );
      case AccountService.notifications:
        return ListTile(
          title: Text('${row['title']}'),
          subtitle: Text('${row['message']}'),
          trailing: row['is_read'] == true ? null : TextButton(
            onPressed: _busy ? null : () => _send(
              "/account/notifications/${row['notification_id']}/read", 'PUT',
            ),
            child: const Text('Mark read'),
          ),
        );
      case AccountService.proofs:
        return Card(
          child: ListTile(
            title: Text("₱${row['amount_paid']} · Bill #${row['bill_id']}"),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("${row['full_name']} · ${row['property_name']}\n"
                    "${row['payment_method']} · Reference: ${row['transaction_reference']}"),
                Wrap(
                  children: [
                    if (row['proof_url'] is String)
                      TextButton(
                        onPressed: () => _openProof(row['proof_url'] as String),
                        child: const Text('Open proof link'),
                      ),
                    for (final decision in {'approved': 'Approve', 'rejected': 'Reject'}.entries)
                      TextButton(
                        onPressed: _busy ? null : () => _send(
                          "/owner/payment-proofs/${row['payment_id']}", 'PUT',
                          {'status': decision.key},
                        ),
                        child: Text(decision.value),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.service.title),
      actions: [
        if (widget.service == AccountService.maintenance)
          IconButton(
            tooltip: 'New maintenance request',
            onPressed: _busy ? null : () => _form(),
            icon: const Icon(Icons.add),
          ),
        IconButton(tooltip: 'Refresh', onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh)),
      ],
    ),
    body: FutureBuilder<dynamic>(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) return Center(child: Text(ownerRequestError(snapshot.error!)));
        final rows = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
        if (rows.isEmpty) return const Center(child: Text('No records yet.'));
        return ListView(padding: const EdgeInsets.all(16), children: rows.map(_row).toList());
      },
    ),
  );
}

class _RequestForm extends StatefulWidget {
  const _RequestForm({required this.payment});
  final bool payment;

  @override
  State<_RequestForm> createState() => _RequestFormState();
}

class _RequestFormState extends State<_RequestForm> {
  final _form = GlobalKey<FormState>();
  String _first = '', _second = '', _proof = '', _method = 'gcash';
  bool _urgent = false;

  String? _required(String? value) => (value ?? '').trim().isEmpty ? 'Required' : null;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.payment ? 'Submit manual payment proof' : 'New maintenance request'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              decoration: InputDecoration(labelText: widget.payment ? 'Amount paid (PHP)' : 'Title'),
              keyboardType: widget.payment ? const TextInputType.numberWithOptions(decimal: true) : null,
              maxLength: widget.payment ? 11 : 150,
              validator: _required,
              onChanged: (value) => _first = value.trim(),
            ),
            TextFormField(
              decoration: InputDecoration(labelText: widget.payment ? 'Payment reference' : 'Description'),
              maxLength: widget.payment ? 100 : 3000,
              maxLines: widget.payment ? 1 : 3,
              validator: _required,
              onChanged: (value) => _second = value.trim(),
            ),
            if (widget.payment) ...[
              DropdownButtonFormField<String>(
                initialValue: _method,
                decoration: const InputDecoration(labelText: 'Method'),
                onChanged: (value) { if (value != null) _method = value; },
                items: const [
                  DropdownMenuItem(value: 'gcash', child: Text('GCash')),
                  DropdownMenuItem(value: 'bank_transfer', child: Text('Bank transfer')),
                  DropdownMenuItem(value: 'cash', child: Text('Cash')),
                ],
              ),
              TextFormField(
                decoration: const InputDecoration(labelText: 'Proof URL (optional)'),
                keyboardType: TextInputType.url,
                onChanged: (value) => _proof = value.trim(),
              ),
            ] else
              SwitchListTile(
                title: const Text('Urgent'), value: _urgent,
                onChanged: (value) => setState(() => _urgent = value),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(
        onPressed: () {
          if (_form.currentState?.validate() != true) return;
          Navigator.of(context).pop(widget.payment ? {
            'amount_paid': _first, 'reference': _second, 'method': _method,
            if (_proof.isNotEmpty) 'proof_url': _proof,
          } : {
            'title': _first, 'description': _second, 'priority': _urgent ? 'urgent' : 'normal',
          });
        },
        child: const Text('Submit'),
      ),
    ],
  );
}
