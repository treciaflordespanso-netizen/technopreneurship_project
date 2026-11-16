import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'owner_tenants.dart';
import 'owner_tools.dart';
import 'session.dart';
import 'room_availability.dart';

class OwnerRoomsPage extends StatefulWidget {
  const OwnerRoomsPage({
    super.key,
    required this.propertyId,
    required this.propertyName,
  });

  final int propertyId;
  final String propertyName;

  @override
  State<OwnerRoomsPage> createState() => _OwnerRoomsPageState();
}

class _OwnerRoomsPageState extends State<OwnerRoomsPage> {
  static const _api = String.fromEnvironment('API_BASE_URL');
  static const _timeout = Duration(seconds: 15);

  late Future<List<Map<String, dynamic>>> _rooms;
  DateTimeRange? _availabilityDates;

  Uri get _url =>
      Uri.parse('$_api/owner/properties/${widget.propertyId}/rooms');

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

  @override
  void initState() {
    super.initState();
    _rooms = _loadRooms();
  }

  Future<List<Map<String, dynamic>>> _loadRooms() async {
    final dates = _availabilityDates;
    final uri = dates == null ? _url : _url.replace(queryParameters: {
      'start_date': dates.start.toIso8601String().split('T').first,
      'end_date': dates.end.toIso8601String().split('T').first,
    });
    final response = await http.get(uri, headers: _headers).timeout(_timeout);

    if (response.statusCode != 200) {
      throw StateError(_errorMessage(response, 'Could not load rooms'));
    }

    final rows = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    return rows.cast<Map<String, dynamic>>();
  }

  String _errorMessage(http.Response response, String fallback) {
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map && body['detail'] is String) {
        return body['detail'] as String;
      }
    } on FormatException {
      // Use the HTTP status for plain-text responses.
    }

    return '$fallback (HTTP ${response.statusCode}).';
  }

  void _refresh() {
    setState(() => _rooms = _loadRooms());
  }

  Future<void> _chooseAvailabilityDates() async {
    final now = DateUtils.dateOnly(DateTime.now());
    final range = await showDateRangePicker(
      context: context,
      firstDate: now,
      lastDate: DateTime(now.year + 5, 12, 31),
      initialDateRange: _availabilityDates,
    );
    if (!mounted || range == null) return;
    setState(() {
      _availabilityDates = range;
      _rooms = _loadRooms();
    });
  }

  void _openTenants(Map<String, dynamic> room) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OwnerTenantsPage(
          propertyId: widget.propertyId,
          roomId: room['room_id'] as int,
          roomNumber: room['room_number'].toString(),
        ),
      ),
    );
  }

  Future<void> _openRoomForm({Map<String, dynamic>? room}) async {
    final editing = room != null;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RoomForm(
        room: room,
        onSave: (fields) async {
          final headers = _headers;
          final body = jsonEncode(fields);
          final request = room == null
              ? http.post(_url, headers: headers, body: body)
              : http.put(
                  _url.replace(
                    pathSegments: [..._url.pathSegments, '${room['room_id']}'],
                  ),
                  headers: headers,
                  body: body,
                );

          final response = await request.timeout(_timeout);
          if (response.statusCode != (editing ? 200 : 201)) {
            throw StateError(
              _errorMessage(
                response,
                editing ? 'Could not update room' : 'Could not save room',
              ),
            );
          }
        },
      ),
    );

    if (!mounted) return;
    _refresh();

    if (saved == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(editing ? 'Room updated.' : 'Room saved.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.propertyName)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => _openRoomForm(),
              icon: const Icon(Icons.add),
              label: const Text('Add Room'),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(children: [
            OutlinedButton.icon(
              onPressed: _chooseAvailabilityDates,
              icon: const Icon(Icons.date_range_outlined),
              label: Text(_availabilityDates == null ? 'Check dates' :
                  "${_availabilityDates!.start.toIso8601String().split('T').first} to "
                  "${_availabilityDates!.end.toIso8601String().split('T').first}"),
            ),
            if (_availabilityDates != null)
              TextButton(
                onPressed: () => setState(() {
                  _availabilityDates = null;
                  _rooms = _loadRooms();
                }),
                child: const Text('Show today'),
              ),
          ]),
          const SizedBox(height: 16),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _rooms,
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
                          : 'Could not load rooms.',
                    ),
                    TextButton(onPressed: _refresh, child: const Text('Retry')),
                  ],
                );
              }

              final rooms = snapshot.data ?? [];
              if (rooms.isEmpty) return const Text('No rooms yet.');

              return LayoutBuilder(
                builder: (context, limits) {
                  final cardWidth = limits.maxWidth >= 690
                      ? (limits.maxWidth - 16) / 2 : limits.maxWidth;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 16, runSpacing: 12,
                        children: [
                          for (final room in rooms)
                            SizedBox(width: cardWidth, child: RoomAvailabilityCard(room: room)),
                        ],
                      ),
                      const SizedBox(height: 20),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('Room')),
                            DataColumn(label: Text('Occupied / capacity')),
                            DataColumn(label: Text('Rent')),
                            DataColumn(label: Text('Availability')),
                            DataColumn(label: Text('Actions')),
                          ],
                          rows: [
                            for (final room in rooms)
                              DataRow(cells: [
                                DataCell(Text("Room ${room['room_number']} · ${room['room_type'] ?? 'Standard'}")),
                                DataCell(Text("${room['occupied_spaces']} / ${room['capacity']}")),
                                DataCell(Text("₱${room['monthly_rate']}")),
                                DataCell(AvailabilityBadge(room: room)),
                                DataCell(Wrap(children: [
                                  IconButton(
                                    tooltip: 'Edit room',
                                    onPressed: () => _openRoomForm(room: room),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Tenants',
                                    onPressed: () => _openTenants(room),
                                    icon: const Icon(Icons.people_outline),
                                  ),
                                  IconButton(
                                    tooltip: 'Reservations',
                                    onPressed: () async {
                                      await Navigator.of(context).push<void>(
                                        MaterialPageRoute(
                                          builder: (_) => ReservationListPage(
                                            path: '/owner/properties/${widget.propertyId}/rooms/${room['room_id']}/reservations',
                                            owner: true,
                                          ),
                                        ),
                                      );
                                      if (mounted) _refresh();
                                    },
                                    icon: const Icon(Icons.event_note_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Maintenance',
                                    onPressed: () => Navigator.of(context).push<void>(
                                      MaterialPageRoute(
                                        builder: (_) => OwnerMaintenancePage(
                                          propertyId: widget.propertyId,
                                          roomId: room['room_id'] as int,
                                          roomNumber: '${room['room_number']}',
                                        ),
                                      ),
                                    ),
                                    icon: const Icon(Icons.build_outlined),
                                  ),
                                ])),
                              ]),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RoomForm extends StatefulWidget {
  const _RoomForm({required this.onSave, this.room});

  final Future<void> Function(Map<String, dynamic>) onSave;
  final Map<String, dynamic>? room;

  @override
  State<_RoomForm> createState() => _RoomFormState();
}

class _RoomFormState extends State<_RoomForm> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _number;
  late final TextEditingController _capacity;
  late final TextEditingController _rate;
  late final TextEditingController _status;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final room = widget.room;
    _number = TextEditingController(text: room?['room_number']?.toString());
    _capacity = TextEditingController(
      text: room?['capacity']?.toString() ?? '1',
    );
    _rate = TextEditingController(text: room?['monthly_rate']?.toString());
    _status = TextEditingController(
      text: room?['room_status']?.toString() ?? 'available',
    );
  }

  @override
  void dispose() {
    _number.dispose();
    _capacity.dispose();
    _rate.dispose();
    _status.dispose();
    super.dispose();
  }

  String? _validateCapacity(String? value) {
    final capacity = int.tryParse((value ?? '').trim());
    if (capacity == null || capacity < 1 || capacity > 2147483647) {
      return 'Enter a valid capacity';
    }
    return null;
  }

  String? _validateRate(String? value) {
    final rate = (value ?? '').trim();
    final amount = double.tryParse(rate);
    if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(rate) ||
        amount == null ||
        !amount.isFinite ||
        amount <= 0) {
      return 'Enter a positive amount, e.g. 2500.00';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_saving || !_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.onSave({
        'room_number': _number.text.trim(),
        'capacity': int.parse(_capacity.text.trim()),
        'monthly_rate': _rate.text.trim(),
        if (widget.room != null) 'room_status': _status.text.trim(),
      });

      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is StateError
            ? error.message
            : 'Save could not be confirmed. Close and check the room list.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.room != null;
    final saveLabel = editing ? 'Save changes' : 'Save room';

    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(editing ? 'Edit Room' : 'Add Room'),
        scrollable: true,
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _number,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Room number'),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _capacity,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Capacity'),
                validator: _validateCapacity,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _rate,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Monthly rent (₱)'),
                validator: _validateRate,
              ),
              if (editing) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _status,
                  enabled: !_saving,
                  decoration: const InputDecoration(labelText: 'Room status'),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Enter a room status' : null,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!),
              ],
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
            child: Text(_saving ? 'Saving…' : saveLabel),
          ),
        ],
      ),
    );
  }
}