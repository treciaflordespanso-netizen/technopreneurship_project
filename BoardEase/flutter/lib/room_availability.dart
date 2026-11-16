import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'owner_tools.dart';
import 'session.dart';

String _date(DateTime value) => value.toIso8601String().split('T').first;

class AvailabilityBadge extends StatelessWidget {
  const AvailabilityBadge({super.key, required this.room});
  final Map<String, dynamic> room;

  @override
  Widget build(BuildContext context) {
    final available = room['is_available'] == true;
    final color = available ? const Color(0xFF087354) : const Color(0xFF9A3412);
    final reason = room['availability_reason'];
    return Chip(
      avatar: Icon(available ? Icons.check_circle_outline : Icons.info_outline,
          color: color, size: 17),
      label: Text(
        available ? 'Available' : 'Unavailable${reason == null || reason == 'Unavailable' ? '' : ' · $reason'}',
        style: TextStyle(color: color),
      ),
    );
  }
}

class RoomAvailabilityCard extends StatelessWidget {
  const RoomAvailabilityCard({
    super.key,
    required this.room,
    this.amenities = const [],
    this.action,
  });
  final Map<String, dynamic> room;
  final List<String> amenities;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final kind = room['room_type']?.toString();
    final image = room['image_url'];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (image is String)
              Image.network(image, height: 110, width: double.infinity, fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.bed_outlined, size: 40))
            else
              const Icon(Icons.bed_outlined, size: 40),
            const SizedBox(height: 8),
            Text(
              kind == null || kind.isEmpty ? 'Room ${room['room_number']}' : '$kind · ${room['room_number']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text('₱${room['monthly_rate']} per month'),
            Text("${room['available_spaces'] ?? 0} of ${room['capacity']} spaces open"),
            AvailabilityBadge(room: room),
            if (amenities.isNotEmpty)
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  for (final amenity in amenities)
                    Text(amenity, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ?action,
          ],
        ),
      ),
    );
  }
}

class PublicPropertyRoomsPage extends StatefulWidget {
  const PublicPropertyRoomsPage({super.key, required this.propertyId});
  final int propertyId;

  @override
  State<PublicPropertyRoomsPage> createState() => _PublicPropertyRoomsPageState();
}

class _PublicPropertyRoomsPageState extends State<PublicPropertyRoomsPage> {
  static const _base = String.fromEnvironment('API_BASE_URL');
  DateTimeRange? _dates;
  late Future<Map<String, dynamic>> _rooms = _load();
  bool _availableOnly = false;
  bool _saving = false;

  Future<Map<String, dynamic>> _load() async {
    final dates = _dates;
    final uri = Uri.parse('$_base/properties/${widget.propertyId}/rooms').replace(
      queryParameters: dates == null ? null : {
        'start_date': _date(dates.start), 'end_date': _date(dates.end),
      },
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError(response.statusCode == 404 ? 'Property unavailable.' : 'Could not load rooms.');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> _chooseDates() async {
    final now = DateUtils.dateOnly(DateTime.now());
    final selection = await showDateRangePicker(
      context: context, firstDate: now, lastDate: DateTime(now.year + 5, 12, 31),
      initialDateRange: _dates,
    );
    if (mounted && selection != null) {
      setState(() {
        _dates = selection;
        _rooms = _load();
      });
    }
  }

  Future<void> _reserve(int roomId) async {
    final dates = _dates;
    if (dates == null || _saving) return;
    if (session.value == null) {
      context.push('/account');
      return;
    }
    setState(() => _saving = true);
    try {
      await ownerRequest(
        '/tenant/properties/${widget.propertyId}/rooms/$roomId/reservations',
        method: 'POST',
        fields: {'start_date': _date(dates.start), 'end_date': _date(dates.end)},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reservation requested. Status: Pending.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ownerRequestError(error))));
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _rooms = _load();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Room availability')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _rooms,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final ready = snapshot.connectionState == ConnectionState.done && data != null;
        final rooms = (data?['rooms'] as List? ?? const []).cast<Map<String, dynamic>>();
        final visible = rooms.where((room) => !_availableOnly || room['is_available'] == true);
        final amenities = (data?['amenities'] as List? ?? const []).cast<String>();
        final listing = data?['property'] as Map<String, dynamic>?;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (listing != null) ...[
              Text('${listing['property_name']}', style: Theme.of(context).textTheme.headlineSmall),
              Text('${listing['address']}'),
              if (listing['description'] != null) Text('${listing['description']}'),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Open in Google Maps'),
                  onPressed: () async {
                    final link = Uri.https('www.google.com', '/maps/search/',
                        {'api': '1', 'query': '${listing['address']}'});
                    try {
                      if (await launchUrl(link)) return;
                    } catch (_) {
                      // Use the same feedback when the platform cannot launch the link.
                    }
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Could not open the map.')),
                      );
                    }
                  },
                ),
              ),
            ],
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.date_range),
                  onPressed: _saving ? null : _chooseDates,
                  label: Text(_dates == null ? 'Choose stay dates' :
                      '${_date(_dates!.start)} to ${_date(_dates!.end)}'),
                ),
                FilterChip(
                  label: const Text('Available only'),
                  selected: _availableOnly,
                  onSelected: (value) => setState(() => _availableOnly = value),
                ),
              ],
            ),
            if (!ready && !snapshot.hasError) const LinearProgressIndicator(),
            if (snapshot.hasError)
              ListTile(
                title: Text(ownerRequestError(snapshot.error!)),
                trailing: TextButton(
                  onPressed: () => setState(() { _rooms = _load(); }),
                  child: const Text('Retry'),
                ),
              ),
            if (ready && visible.isEmpty) const ListTile(title: Text('No matching rooms.')),
            if (ready)
              LayoutBuilder(builder: (context, limits) {
                final width = limits.maxWidth >= 720 ? (limits.maxWidth - 12) / 2 : limits.maxWidth;
                return Wrap(
                  spacing: 12, runSpacing: 12,
                  children: [
                    for (final room in visible)
                      SizedBox(
                        width: width,
                        child: RoomAvailabilityCard(
                          room: room,
                          amenities: amenities,
                          action: FilledButton(
                            onPressed: !_saving && _dates != null &&
                                room['is_available'] == true && session.value?.role != 'owner'
                                ? () => _reserve(room['room_id'] as int) : null,
                            child: const Text('Request Reservation'),
                          ),
                        ),
                      ),
                  ],
                );
              }),
            if (ready)
              for (final rule in (data['rules'] as List? ?? const []))
                ListTile(leading: const Icon(Icons.rule_outlined),
                  title: Text('${rule['rule_title']}'), subtitle: Text('${rule['rule_description']}')),
            if (ready)
              for (final review in (data['reviews'] as List? ?? const []))
                ListTile(leading: const Icon(Icons.star_outline),
                  title: Text("${review['rating']} / 5"),
                  subtitle: Text(review['review_comment']?.toString() ?? '')),
          ],
        );
      },
    ),
  );
}

class ReservationListPage extends StatefulWidget {
  const ReservationListPage({super.key, required this.path, this.owner = false});
  final String path;
  final bool owner;

  @override
  State<ReservationListPage> createState() => _ReservationListPageState();
}

class _ReservationListPageState extends State<ReservationListPage> {
  late Future<dynamic> _request = ownerRequest(widget.path);
  bool _busy = false;

  Future<void> _update(int id, String status) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (status == 'move_in') {
        await ownerRequest('/owner/reservations/$id/move-in', method: 'PUT');
      } else {
        await ownerRequest('/owner/reservations/$id/status', method: 'PUT', fields: {'status': status});
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ownerRequestError(error))));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _request = ownerRequest(widget.path);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reservations')),
    body: FutureBuilder<dynamic>(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(ownerRequestError(snapshot.error!)),
            TextButton(onPressed: () => setState(() { _request = ownerRequest(widget.path); }),
              child: const Text('Retry')),
          ]));
        }
        final rows = snapshot.data as List<dynamic>;
        if (rows.isEmpty) return const Center(child: Text('No reservations yet.'));
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final row in rows)
              ListTile(
                title: Text(widget.owner
                    ? "${row['full_name'] ?? 'Reservation'} · #${row['reservation_id']}"
                    : "${row['property_name']} · Room ${row['room_number']}"),
                subtitle: Text(
                  "${row['preferred_move_in_date'] ?? 'Date not set'}"
                  "${row['requested_end_date'] == null ? '' : " to ${row['requested_end_date']}"}"
                  " · ${row['reservation_status']}"
                  "${row['agreement_id'] == null ? '' : "\nAgreement #${row['agreement_id']}"}",
                ),
                trailing: widget.owner && row['reservation_status'] == 'pending'
                    ? PopupMenuButton<String>(
                        enabled: !_busy,
                        tooltip: 'Update reservation',
                        onSelected: (value) => _update(row['reservation_id'] as int, value),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'approved', child: Text('Approve')),
                          PopupMenuItem(value: 'rejected', child: Text('Reject')),
                          PopupMenuItem(value: 'cancelled', child: Text('Cancel reservation')),
                        ],
                      )
                    : widget.owner && row['agreement_status'] == 'pending'
                        ? TextButton(
                            onPressed: _busy ? null : () => _update(row['reservation_id'] as int, 'move_in'),
                            child: const Text('Move in'),
                          )
                        : null,
              ),
          ],
        );
      },
    ),
  );
}
