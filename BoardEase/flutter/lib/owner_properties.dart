import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

import 'owner_rooms.dart';
import 'owner_tools.dart';
import 'session.dart';

class OwnerProperties extends StatefulWidget {
  const OwnerProperties({super.key});

  @override
  State<OwnerProperties> createState() => _OwnerPropertiesState();
}

class _OwnerPropertiesState extends State<OwnerProperties> {
  static const api = String.fromEnvironment('API_BASE_URL');
  static const timeout = Duration(seconds: 15);

  late Future<List<Map<String, dynamic>>> _properties;

  @override
  void initState() {
    super.initState();
    _properties = _loadProperties();
  }

  Map<String, String> get _headers {
    final active = session.value;
    if (active == null) {
      throw StateError('Please sign in again.');
    }

    return {
      'Authorization': 'Bearer ${active.token}',
      'Content-Type': 'application/json',
    };
  }

  Uri get _url => Uri.parse('$api/owner/properties');

  Future<List<Map<String, dynamic>>> _loadProperties() async {
    final response = await http.get(_url, headers: _headers).timeout(timeout);

    if (response.statusCode != 200) {
      throw StateError('Could not load properties.');
    }

    final rows = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    return rows.cast<Map<String, dynamic>>();
  }

  Future<void> _saveProperty(Map<String, String> fields) async {
    final response = await http
        .post(_url, headers: _headers, body: jsonEncode(fields))
        .timeout(timeout);

    if (response.statusCode != 201) {
      throw StateError('Could not save the property.');
    }
  }

  void _refresh() {
    setState(() => _properties = _loadProperties());
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AddPropertyForm(
        existing: existing,
        onSave: existing == null ? _saveProperty : (fields) async {
          await ownerRequest("/owner/properties/${existing['property_id']}",
              method: 'PUT', fields: fields);
        },
      ),
    );

    if (!mounted) return;

    _refresh();
    if (saved == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(existing == null
            ? 'Property saved as a private draft.' : 'Property updated.')),
      );
    }
  }

  Future<void> _listingAction(Map<String, dynamic> row, String action) async {
    if (action == 'edit') {
      await _openForm(existing: row);
      return;
    }
    if (action == 'archive') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Archive this property?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Archive')),
          ],
        ),
      );
      if (!mounted || confirm != true) return;
    }
    try {
      await ownerRequest("/owner/properties/${row['property_id']}/listing",
          method: 'PUT', fields: {'action': action});
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ownerRequestError(error))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _properties,
      builder: (context, snapshot) {
        final rows = snapshot.data ?? [];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FilledButton.icon(
              onPressed: _openForm,
              icon: const Icon(Icons.add),
              label: const Text('Add Property'),
            ),
            const SizedBox(height: 16),
            if (snapshot.connectionState == ConnectionState.waiting)
              const LinearProgressIndicator()
            else if (snapshot.hasError)
              TextButton(
                onPressed: _refresh,
                child: const Text('Could not load properties. Try again.'),
              )
            else ...[
              Text('Your properties (${rows.length})'),
              if (rows.isEmpty) const Text('You have no properties yet.'),
              for (final row in rows)
                ListTile(
                  title: Text(row['property_name'] as String),
                  subtitle: Text("${row['address']}\n${row['is_public'] == true ? 'Published' : (row['verified'] == true ? 'Unpublished' : 'Awaiting verification')}"),
                  trailing: Wrap(children: [IconButton(
                    tooltip: 'Open in Google Maps',
                    icon: const Icon(Icons.map_outlined),
                    onPressed: () async {
                      final uri = Uri.https('www.google.com', '/maps/search/', {
                        'api': '1',
                        'query': row['address'] as String,
                      });
                      try {
                        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
                      } catch (_) {
                        // Show a message if no handler opens the link.
                      }
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Could not open Google Maps.')),
                      );
                    },
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Property actions',
                    onSelected: (action) => _listingAction(row, action),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
                      if (row['is_public'] == true)
                        const PopupMenuItem(value: 'unpublish', child: Text('Unpublish'))
                      else if (row['verified'] == true)
                        const PopupMenuItem(value: 'publish', child: Text('Publish')),
                      const PopupMenuItem(value: 'archive', child: Text('Archive')),
                    ],
                  ),
                  ]),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => OwnerRoomsPage(
                          propertyId: row['property_id'] as int,
                          propertyName: row['property_name'] as String,
                        ),
                      ),
                    );
                  },
                ),
            ],
          ],
        );
      },
    );
  }
}

class _AddPropertyForm extends StatefulWidget {
  const _AddPropertyForm({required this.onSave, this.existing});

  final Map<String, dynamic>? existing;

  final Future<void> Function(Map<String, String>) onSave;

  @override
  State<_AddPropertyForm> createState() => _AddPropertyFormState();
}

class _AddPropertyFormState extends State<_AddPropertyForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?['property_name']?.toString());
  late final _address = TextEditingController(text: widget.existing?['address']?.toString());
  late final _description = TextEditingController(text: widget.existing?['description']?.toString());

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _description.dispose();
    super.dispose();
  }

  String? _requiredField(String? value) {
    return (value ?? '').trim().isEmpty ? 'Required' : null;
  }

  Future<void> _submit() async {
    if (_saving || !_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.onSave({
        'property_name': _name.text.trim(),
        'address': _address.text.trim(),
        'description': _description.text.trim(),
      });

      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _saving = false;
        _error = 'Could not confirm the save. Close the form and check your '
            'property list before retrying.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(widget.existing == null ? 'Add Property' : 'Edit Property'),
        scrollable: true,
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                enabled: !_saving,
                maxLength: 150,
                validator: _requiredField,
                decoration: const InputDecoration(labelText: 'Property name'),
              ),
              TextFormField(
                controller: _address,
                enabled: !_saving,
                maxLength: 500,
                validator: _requiredField,
                decoration: const InputDecoration(labelText: 'Address'),
              ),
              TextFormField(
                controller: _description,
                enabled: !_saving,
                maxLength: 2000,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
              ),
              if (_error != null) Text(_error!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: Text(_saving ? 'Saving…' : 'Save property'),
          ),
        ],
      ),
    );
  }
}