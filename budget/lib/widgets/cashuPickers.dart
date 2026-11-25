import 'package:budget/widgets/cashuSurfaces.dart';
import 'package:budget/widgets/currencyPicker.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

Future<String?> pickCashuCurrency(BuildContext context, String current) =>
    Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (context) => PageFramework(
        title: cashuLabel(context, 'Choose currency', 'اختار العملة'),
        backgroundColor: CashuColors(context).canvas,
        horizontalPaddingConstrained: true,
        slivers: [
          CurrencyPicker(
            initialCurrency: current,
            showExchangeRateInfoNotice: true,
            onSelected: (code) => Navigator.of(context).pop(code),
          ),
        ],
      ),
    ));

Future<String?> pickCashuInstitution(BuildContext context, String? current,
        {required bool mobileWallet}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          _InstitutionPicker(current: current, mobileWallet: mobileWallet),
    );

class _InstitutionPicker extends StatefulWidget {
  const _InstitutionPicker({required this.current, required this.mobileWallet});
  final String? current;
  final bool mobileWallet;

  @override
  State<_InstitutionPicker> createState() => _InstitutionPickerState();
}

class _InstitutionPickerState extends State<_InstitutionPicker> {
  static const _banks = [
    ('National Bank of Egypt', 'البنك الأهلي المصري', 'NBE الأهلي الاحلي'),
    ('Banque Misr', 'بنك مصر', 'BM مصر'),
    ('CIB', 'البنك التجاري الدولي', 'CIB التجاري'),
    ('QNB', 'بنك قطر الوطني', 'QNB قطر الوطني bebasata'),
    ('ABK Egypt', 'البنك الأهلي الكويتي', 'ABK اهلي كويتي'),
    ('Bank of Alexandria', 'بنك الإسكندرية', 'AlexBank الاسكندرية'),
    ('Banque du Caire', 'بنك القاهرة', 'BDC القاهرة'),
    (
      'Arab African International Bank',
      'البنك العربي الأفريقي',
      'AAIB العربي الأفريقي'
    ),
    ('ADIB Egypt', 'مصرف أبوظبي الإسلامي', 'ADIB أبو ظبي الاسلامي'),
    ('Telda', 'تيلدا', 'Telda تيلدا تلدا'),
  ];
  static const _wallets = [
    ('Vodafone Cash', 'فودافون كاش', 'Vodafone فودافون'),
    ('Orange Cash', 'أورنج كاش', 'Orange اورنج'),
    ('e& cash', 'اتصالات كاش', 'Etisalat اتصالات إي آند'),
    ('WE Pay', 'وي باي', 'WE وي'),
  ];
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final colors = CashuColors(context);
    final en = Localizations.localeOf(context).languageCode != 'ar';
    String label(String english, String arabic) =>
        cashuLabel(context, english, arabic);
    String normalize(String value) =>
        value.toLowerCase().replaceAll(RegExp('[أإآ]'), 'ا');
    final choices = widget.mobileWallet ? _wallets : _banks;
    final query = _query.trim();
    final current = widget.current;
    final matches = choices.where((item) => normalize(
          '${item.$1} ${item.$2} ${item.$3}',
        ).contains(normalize(query)));
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 550),
        child: Material(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          color: colors.canvas,
          child: Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .58,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        CashuSectionTitle(widget.mobileWallet
                            ? label('Choose a wallet', 'اختار المحفظة')
                            : label('Bank or provider', 'البنك أو التطبيق')),
                        TextField(
                          maxLength: 60,
                          decoration: cashuInput(
                              context,
                              label('Find a provider or type a name',
                                  'ابحث أو اكتب الاسم')),
                          onChanged: (value) => setState(() => _query = value),
                        ),
                      ]),
                ),
                Expanded(
                    child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    if (query.isEmpty && current != null && current.isNotEmpty)
                      CashuActionRow(
                          icon: Icons.remove_circle_outline,
                          title: label(
                              'Clear saved provider', 'امسح اسم البنك المحفوظ'),
                          onTap: () => Navigator.pop(context, '')),
                    if (query.isNotEmpty &&
                        !choices.any((item) =>
                            normalize(item.$1) == normalize(query) ||
                            normalize(item.$2) == normalize(query)))
                      CashuActionRow(
                          icon: Icons.add,
                          title: label('Use “$query”', 'استخدم «$query»'),
                          onTap: () => Navigator.pop(context, query)),
                    for (final (code, ar, _) in matches)
                      CashuActionRow(
                          icon: widget.mobileWallet
                              ? Icons.phone_iphone_outlined
                              : Icons.account_balance_outlined,
                          title: en ? code : ar,
                          detail: code == current
                              ? label('Selected', 'محدّد')
                              : null,
                          onTap: () => Navigator.pop(context, code)),
                  ],
                )),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
