import 'package:budget/functions.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/pages/bankCertificatesPage.dart';
import 'package:budget/pages/investmentsPage.dart';
import 'package:budget/pages/wealthAssetsPage.dart';
import 'package:budget/struct/accountTypes.dart';
import 'package:budget/widgets/cashuSurfaces.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:flutter/material.dart';

IconData cashuAccountIcon(String type) => switch (type) {
      'bank' => Icons.account_balance_outlined,
      'debit' || 'prepaid' => Icons.credit_card_rounded,
      'credit' => Icons.credit_score_outlined,
      'cash' => Icons.payments_outlined,
      'ewallet' => Icons.phone_iphone_rounded,
      'savings' => Icons.savings_outlined,
      'investment' => Icons.show_chart_rounded,
      _ => Icons.account_balance_wallet_outlined,
    };

class CashuAddAssetPage extends StatelessWidget {
  const CashuAddAssetPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = CashuColors(context);
    String label(String en, String ar) => cashuLabel(context, en, ar);
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    const descriptions = {
      'bank': ('Track your bank balance', 'تابع رصيد حسابك في البنك'),
      'debit': ('A card linked to your funds', 'بطاقة مرتبطة برصيدك'),
      'credit': (
        'Limit, statement and payment dates',
        'الحد والكشف وموعد السداد'
      ),
      'cash': ('Cash on hand', 'الفلوس النقدية معاك'),
      'ewallet': (
        'Mobile and digital wallets',
        'محافظ الموبايل والمحافظ الرقمية'
      ),
      'prepaid': ('Track a loaded card balance', 'تابع رصيد البطاقة المشحونة'),
      'savings': ('Money set aside', 'فلوس مخصصة للادخار'),
      'investment': ('An account used for investing', 'حساب مخصص للاستثمار'),
      'unspecified': ('Other accounts', 'الحسابات الأخرى'),
    };
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        title: Text(label('Add to CashU', 'إضافة إلى CashU')),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                CashuPanel(
                  highlighted: true,
                  onTap: () => pushRoute(
                      context, const BankCertificatesPage(openForm: true)),
                  child: _AddAssetLabel(
                    icon: Icons.workspace_premium_outlined,
                    title: label('Bank certificate', 'شهادة بنكية'),
                    subtitle: label('Track principal and scheduled returns',
                        'تابع قيمة الشهادة والعوائد الدورية'),
                  ),
                ),
                CashuSectionTitle(
                    label('Accounts and cards', 'الحسابات والبطاقات')),
                LayoutBuilder(builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 310 &&
                          MediaQuery.textScalerOf(context).scale(16) < 24
                      ? 2
                      : 1;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 10) / columns;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final entry in descriptions.entries)
                        SizedBox(
                          width: width,
                          child: CashuPanel(
                            padding: const EdgeInsets.all(12),
                            onTap: () => pushRoute(
                                context,
                                AddWalletPage(
                                  initialAccountType: entry.key,
                                  routesToPopAfterDelete:
                                      RoutesToPopAfterDelete.None,
                                )),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CashuIconTile(cashuAccountIcon(entry.key),
                                    size: 36),
                                const SizedBox(height: 8),
                                Text(
                                    accountTypeLabel(entry.key, arabic: arabic),
                                    style: TextStyle(
                                        color: colors.ink,
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 2),
                                Text(label(entry.value.$1, entry.value.$2),
                                    style: TextStyle(
                                        color: colors.muted, fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                }),
                CashuSectionTitle(label('Assets and debt', 'الأصول والديون')),
                for (final (type, icon, en, ar, detail, detailAr) in [
                  (
                    'property',
                    Icons.home_work_outlined,
                    'Property or other asset',
                    'عقار أو أصل آخر',
                    'Record a manual valuation',
                    'سجّل تقييمًا يدويًا'
                  ),
                  (
                    'gold',
                    Icons.diamond_outlined,
                    'Gold',
                    'ذهب',
                    'Enter quantity and price',
                    'أدخل الكمية والسعر'
                  ),
                  (
                    'silver',
                    Icons.layers_outlined,
                    'Silver',
                    'فضة',
                    'Enter quantity and price',
                    'أدخل الكمية والسعر'
                  ),
                  (
                    'debt',
                    Icons.receipt_long_outlined,
                    'Debt',
                    'دين',
                    'Track a liability',
                    'تابع التزامًا ماليًا'
                  ),
                  (
                    'investments',
                    Icons.stacked_line_chart_rounded,
                    'Investments',
                    'استثمارات',
                    'Manage holdings',
                    'إدارة حيازاتك'
                  ),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: CashuPanel(
                      onTap: () => pushRoute(
                          context,
                          type == 'investments'
                              ? const InvestmentsPage()
                              : WealthAssetsPage(initialAssetType: type)),
                      child: _AddAssetLabel(
                        icon: icon,
                        title: label(en, ar),
                        subtitle: label(detail, detailAr),
                          ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddAssetLabel extends StatelessWidget {
  const _AddAssetLabel(
      {required this.icon,
      required this.title,
      required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = CashuColors(context);
    return Row(children: [
      CashuIconTile(icon),
      const SizedBox(width: 12),
      Expanded(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(color: colors.ink, fontWeight: FontWeight.w800)),
          Text(subtitle, style: TextStyle(color: colors.muted)),
        ],
      )),
      const _ForwardIcon(),
    ]);
  }
}

class _ForwardIcon extends StatelessWidget {
  const _ForwardIcon();
  @override
  Widget build(BuildContext context) => Icon(
        Directionality.of(context) == TextDirection.rtl
            ? Icons.chevron_left_rounded
            : Icons.chevron_right_rounded,
        color: CashuColors(context).muted,
      );
}
