import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

typedef _Member = ({String id, String name, String role});
typedef _Access = ({
  String id,
  String name,
  String? currency,
  bool canView,
  bool canEdit,
});

class HouseholdPage extends StatefulWidget {
  const HouseholdPage({super.key});

  @override
  State<HouseholdPage> createState() => _HouseholdPageState();
}

class _HouseholdPageState extends State<HouseholdPage> {
  late var _members = database.getLocalHouseholdMembers();
  Future<List<_Access>>? _access;
  _Member? _selected;
  bool _busy = false;

  String _label(String english, String arabic) =>
      Localizations.localeOf(context).languageCode == 'ar' ? arabic : english;

  String _role(String role) => switch (role) {
        'owner' => _label('Owner', 'مالك'),
        'editor' => _label('Editor', 'محرر'),
        _ => _label('Viewer', 'مشاهد'),
      };

  void _select(_Member? member) {
    _selected = member;
    _access = member == null
        ? null
        : database.getLocalHouseholdAccountAccess(member.id);
  }

  Future<void> _write(Future<void> Function() action,
      {bool reloadMembers = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      setState(() {
        if (reloadMembers) _members = database.getLocalHouseholdMembers();
        _select(_selected);
      });
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
          _label('Could not save household settings.',
              'تعذّر حفظ إعدادات الأسرة.'),
        )));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([_Member? member]) async {
    final draft = await showDialog<({String name, String role})>(
      context: context,
      builder: (_) =>
          _MemberEditor(initial: member, label: _label, roleLabel: _role),
    );
    if (!mounted || draft == null) return;
    final id = member?.id ?? uuid.v4();
    await _write(() async {
      await database.saveHouseholdMember(
          memberPk: id, displayName: draft.name, role: draft.role);
      if (mounted) _selected = (id: id, name: draft.name, role: draft.role);
    }, reloadMembers: true);
  }

  Future<void> _remove(_Member member) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_label('Remove this profile?', 'حذف هذا الملف الشخصي؟')),
        content: Text(member.name),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_label('Cancel', 'إلغاء'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_label('Remove', 'حذف'))),
        ],
      ),
    );
    if (!mounted || confirm != true) return;
    await _write(() async {
      await database.removeLocalHouseholdMember(member.id);
      if (_selected?.id == member.id) _selected = null;
    }, reloadMembers: true);
  }

  Future<void> _preview(_Member member) {
    final balances =
        database.previewLocalHouseholdBalances(member.id, DateTime.now());
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(_label('Account preview for ${member.name}',
            'معاينة الحسابات لـ${member.name}')),
        content: FutureBuilder(
          future: balances,
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Text(
                  _label('Could not load balances.', 'تعذّر تحميل الأرصدة.'));
            final rows = snapshot.data;
            if (rows == null) return const LinearProgressIndicator();
            if (rows.isEmpty)
              return Text(_label('No accounts in this preview.',
                  'لا توجد حسابات في المعاينة.'));
            return Column(mainAxisSize: MainAxisSize.min, children: [
              for (final row in rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(row.name),
                  subtitle: Text(
                      '${row.balance.toStringAsFixed(2)} ${row.currency?.toUpperCase() ?? ''}'
                          .trim()),
                ),
            ]);
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_label('Done', 'تم'))),
        ],
      ),
    );
  }

  Widget _accountAccess(_Member member) => FutureBuilder<List<_Access>>(
        key: ValueKey(member.id),
        future: _access,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done)
            return const LinearProgressIndicator();
          if (snapshot.hasError)
            return Text(_label('Could not load account access.',
                'تعذّر تحميل صلاحيات الحسابات.'));
          return Column(children: [
            for (final account in snapshot.data!)
              if (member.role == 'owner')
                ListTile(
                    title: Text(account.name),
                    subtitle: Text(_label('Full access', 'صلاحية كاملة')))
              else
                SwitchListTile(
                  title: Text(account.name),
                  subtitle: member.role == 'editor' && account.canView
                      ? TextButton(
                          onPressed: _busy
                              ? null
                              : () => _write(() =>
                                  database.setHouseholdAccountAccess(
                                      memberPk: member.id,
                                      walletPk: account.id,
                                      canView: true,
                                      canEdit: !account.canEdit)),
                          child: Text(account.canEdit
                              ? _label('Can edit · tap for view only',
                                  'يسمح بالتعديل · اضغط للعرض فقط')
                              : _label('View only · tap to allow editing',
                                  'عرض فقط · اضغط للسماح بالتعديل')),
                        )
                      : null,
                  value: account.canView,
                  onChanged: _busy
                      ? null
                      : (view) => _write(() =>
                          database.setHouseholdAccountAccess(
                              memberPk: member.id,
                              walletPk: account.id,
                              canView: view,
                              canEdit: false)),
                ),
          ]);
        },
      );

  @override
  Widget build(BuildContext context) => PageFramework(
        title: _label('Household profiles', 'ملفات أفراد الأسرة'),
        capitalizeTitle: false,
        listWidgets: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_label(
                    'Profiles and access previews are local to this device. Invitations and sharing across devices are not available.',
                    'الملفات ومعاينة الصلاحيات محلية على هذا الجهاز. الدعوات والمشاركة بين الأجهزة غير متاحة.',
                  )),
                  FilledButton(
                      onPressed: _busy ? null : () => _edit(),
                      child: Text(_label('Add profile', 'إضافة ملف شخصي'))),
                ]),
          ),
          FutureBuilder<List<_Member>>(
            future: _members,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done)
                return const LinearProgressIndicator();
              if (snapshot.hasError)
                return ListTile(
                    title: Text(_label(
                        'Could not load profiles.', 'تعذّر تحميل الملفات.')));
              final members = snapshot.data!;
              return Column(children: [
                for (final member in members)
                  ListTile(
                    selected: _selected?.id == member.id,
                    title: Text(member.name),
                    subtitle: Text(_role(member.role)),
                    onTap: _busy ? null : () => setState(() => _select(member)),
                    trailing: IconButton(
                      tooltip: _label('Edit profile', 'تعديل الملف'),
                      onPressed: _busy ? null : () => _edit(member),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ),
              ]);
            },
          ),
          if (_selected case final member?) ...[
            Wrap(alignment: WrapAlignment.center, children: [
              TextButton(
                  onPressed: _busy ? null : () => _preview(member),
                  child: Text(_label(
                      'Preview visible balances', 'معاينة الأرصدة المرئية'))),
              TextButton(
                  onPressed: _busy ? null : () => _remove(member),
                  child: Text(_label('Remove profile', 'حذف الملف'))),
            ]),
            _accountAccess(member),
          ],
        ],
      );
}

class _MemberEditor extends StatefulWidget {
  const _MemberEditor(
      {this.initial, required this.label, required this.roleLabel});
  final _Member? initial;
  final String Function(String, String) label;
  final String Function(String) roleLabel;

  @override
  State<_MemberEditor> createState() => _MemberEditorState();
}

class _MemberEditorState extends State<_MemberEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial?.name);
  late var _role = widget.initial?.role ?? 'viewer';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.initial == null
          ? label('Add profile', 'إضافة ملف شخصي')
          : label('Edit profile', 'تعديل الملف')),
      content: Form(
        key: _form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            controller: _name,
            maxLength: 100,
            decoration: InputDecoration(labelText: label('Name', 'الاسم')),
            validator: (value) => value?.trim().isNotEmpty == true
                ? null
                : label('Enter a name', 'أدخل اسمًا'),
          ),
          DropdownButton<String>(
            isExpanded: true,
            value: _role,
            items: [
              for (final role in ['owner', 'editor', 'viewer'])
                DropdownMenuItem(
                    value: role, child: Text(widget.roleLabel(role))),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _role = value);
            },
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(label('Cancel', 'إلغاء'))),
        FilledButton(
            onPressed: () {
              if (_form.currentState!.validate()) {
                Navigator.pop(context, (name: _name.text.trim(), role: _role));
              }
            },
            child: Text(label('Save', 'حفظ'))),
      ],
    );
  }
}
