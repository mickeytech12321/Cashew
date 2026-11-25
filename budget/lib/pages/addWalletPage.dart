import 'package:budget/pages/cashuAddAssetPage.dart' show cashuAccountIcon;
import 'package:budget/widgets/cashuPickers.dart';
import 'package:budget/widgets/cashuSurfaces.dart';
import 'package:budget/struct/accountTypes.dart';
import 'package:budget/struct/instaPayTransfer.dart';
import 'package:budget/pages/cardStatementsPage.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/editWalletsPage.dart';
import 'package:budget/pages/financialImportPage.dart';
import 'package:budget/pages/settingsPage.dart';
import 'package:budget/struct/cardStatementRepayment.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/animatedExpanded.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/saveBottomButton.dart';
import 'package:budget/widgets/selectAmount.dart';
import 'package:budget/widgets/selectColor.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/transactionEntry/incomeAmountArrow.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:budget/colors.dart';
import 'package:provider/provider.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

class AddWalletPage extends StatefulWidget {
  AddWalletPage({
    Key? key,
    this.wallet,
    required this.routesToPopAfterDelete,
    this.runWhenOpen,
    this.initialAccountType = 'unspecified',
  }) : super(key: key);

  //When a wallet is passed in, we are editing that wallet
  final TransactionWallet? wallet;
  final RoutesToPopAfterDelete routesToPopAfterDelete;
  final VoidCallback? runWhenOpen;
  final String initialAccountType;

  @override
  _AddWalletPageState createState() => _AddWalletPageState();
}

class _AddWalletPageState extends State<AddWalletPage> {
  late final String _walletPk = widget.wallet?.walletPk ?? uuid.v4();
  late bool _detailsReady = widget.wallet == null;
  bool _detailsFailed = false;
  bool _saving = false;

  String? selectedTitle;
  late Color? selectedColor =
      widget.wallet?.colour == null ? null : HexColor(widget.wallet?.colour);
  String selectedCurrency =
      getDevicesDefaultCurrencyCode(); //if no currency selected use empty string
  int selectedDecimals = 2;
  String selectedAccountType = 'unspecified';
  String? institutionName;
  bool accountArchived = false;
  bool excludeFromNetWorth = false;
  double? creditLimit;
  int? statementDay;
  int? dueDay;
  double? minimumPayment;
  double? minimumPercent;
  double? lateFee;
  double? aprPercent;
  String? cardLastFour;
  String? _newCardLastFour;
  String? linkedBankWalletPk;
  late final _linkableWallets = database.getAllWallets();
  Future<Map<String, dynamic>>? _creditSummary;
  final _accountForm = GlobalKey<FormState>();

  String _accountLabel(String english, String arabic) =>
      Localizations.localeOf(context).languageCode == 'ar' ? arabic : english;

  String? _validateCreditNumber(String? value, {double? max}) {
    if (value == null || value.trim().isEmpty) return null;
    final normalized = FinancialMessageParser.normalize(value.trim());
    final number = double.tryParse(normalized);
    if (number != null &&
        number.isFinite &&
        number >= 0 &&
        (max == null || number <= max)) {
      return null;
    }
    return _accountLabel('Enter a valid number', 'أدخل رقمًا صالحًا');
  }

  Widget _creditAccountDetails() {
    return FutureBuilder<List<TransactionWallet>>(
      future: _linkableWallets,
      builder: (context, snapshot) {
        final wallets = snapshot.data
                ?.where((wallet) => wallet.walletPk != widget.wallet?.walletPk)
                .toList() ??
            [];
        final linkedWallet = wallets
            .where((wallet) => wallet.walletPk == linkedBankWalletPk)
            .firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButton<String>(
              isExpanded: true,
              value: linkedWallet?.walletPk ?? '',
              items: [
                DropdownMenuItem(
                  value: '',
                  child: Text(_accountLabel(
                      'No repayment account', 'بدون حساب للسداد')),
                ),
                for (final wallet in wallets)
                  DropdownMenuItem(
                      value: wallet.walletPk, child: Text(wallet.name)),
              ],
              onChanged: snapshot.hasData
                  ? (value) {
                      setState(() =>
                          linkedBankWalletPk = value == '' ? null : value);
                    }
                  : null,
            ),
            if (_creditSummary != null)
              FutureBuilder<Map<String, dynamic>>(
                future: _creditSummary,
                builder: (context, snapshot) {
                  final outstanding = snapshot.data?['outstanding'] as num?;
                  final available = snapshot.data?['available_credit'] as num?;
                  if (outstanding == null) return const SizedBox.shrink();
                  final currency = widget.wallet?.currency?.toUpperCase() ?? '';
                  final statement =
                      snapshot.data?['next_statement_date'] as DateTime?;
                  final due = snapshot.data?['next_due_date'] as DateTime?;
                  final closing =
                      snapshot.data?['last_statement_date'] as DateTime?;
                  final statementDue =
                      snapshot.data?['last_statement_due_date'] as DateTime?;
                  final statementBalance =
                      snapshot.data?['estimated_statement_balance'] as num?;
                  final statementRemaining =
                      snapshot.data?['estimated_statement_remaining'] as num?;
                  final utilization =
                      snapshot.data?['utilization_percent'] as num?;
                  final overLimit = snapshot.data?['over_limit_amount'] as num?;
                  final credits = snapshot.data?['statement_credits'] as num?;
                  final charges =
                      snapshot.data?['charges_after_statement'] as num?;
                  final minimum =
                      snapshot.data?['estimated_minimum_remaining'] as num?;
                  final fee = snapshot.data?['estimated_late_fee'] as num?;
                  final overdue =
                      snapshot.data?['estimated_statement_overdue'] == true;
                  final dates = MaterialLocalizations.of(context);
                  String amount(num value) =>
                      '${value.toStringAsFixed(selectedDecimals)} $currency'
                          .trim();
                  final summary = [
                    '${outstanding.toStringAsFixed(selectedDecimals)} $currency',
                    if (closing != null && statementBalance != null)
                      '${_accountLabel('Estimated statement balance', 'رصيد كشف الحساب التقديري')} '
                          '${statementBalance.toStringAsFixed(selectedDecimals)} $currency · '
                          '${dates.formatMediumDate(closing)}',
                    if (statementRemaining != null)
                      '${_accountLabel('Estimated remaining statement balance', 'المتبقي التقديري من كشف الحساب')} '
                          '${statementRemaining.toStringAsFixed(selectedDecimals)} $currency',
                    if (minimum != null)
                      '${_accountLabel('Estimated minimum remaining', 'المتبقي من الحد الأدنى التقديري')} ${amount(minimum)}',
                    if (fee != null)
                      '${_accountLabel('Estimated late fee', 'رسوم التأخير التقديرية')} ${amount(fee)}',
                    if (credits != null && credits > 0)
                      '${_accountLabel('Credits since closing', 'المبالغ الدائنة بعد الإقفال')} ${amount(credits)}',
                    if (charges != null && charges > 0)
                      '${_accountLabel('Charges since closing', 'المصروفات بعد الإقفال')} ${amount(charges)}',
                    if (utilization != null)
                      '${_accountLabel('Credit used', 'نسبة استخدام الحد')} ${utilization.toStringAsFixed(1)}%',
                    if (overLimit != null && overLimit > 0)
                      '${_accountLabel('Over credit limit', 'تجاوز حد الائتمان')} ${amount(overLimit)}',
                    if (overdue)
                      _accountLabel('Estimated statement payment overdue',
                          'سداد كشف الحساب التقديري متأخر'),
                    if (statementDue != null)
                      '${_accountLabel('Statement due date', 'استحقاق كشف الحساب')} '
                          '${dates.formatMediumDate(statementDue)}',
                    if (available != null)
                      '${_accountLabel('Available', 'المتاح')} '
                          '${available.toStringAsFixed(selectedDecimals)} $currency',
                    if (statement != null)
                      '${_accountLabel('Next statement', 'كشف الحساب القادم')} '
                          '${dates.formatMediumDate(statement)}',
                    if (due != null)
                      '${_accountLabel('Next due date', 'تاريخ الاستحقاق القادم')} '
                          '${dates.formatMediumDate(due)}',
                  ];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                        _accountLabel('Outstanding balance', 'الرصيد المستحق')),
                    subtitle: Text(summary.join('\n')),
                  );
                },
              ),
            if (widget.wallet != null && _creditSummary != null)
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) =>
                          CardStatementsPage(wallet: widget.wallet!)),
                ),
                child: Text(_accountLabel('Card statements', 'كشوف البطاقة')),
              ),
            if (linkedWallet != null &&
                widget.wallet != null &&
                _creditSummary != null)
              OutlinedButton(
                onPressed: () async {
                  final result = await openBalanceTransfer(
                    context,
                    TransferBalancePage(
                      wallet: linkedWallet,
                      initialTarget: widget.wallet,
                      initialTitle: _accountLabel(
                          'Credit card repayment', 'سداد بطاقة ائتمان'),
                      allowEditWallet: false,
                    ),
                  );
                  if (mounted && result == true) {
                    setState(() => _creditSummary =
                        database.getCreditCardSummary(widget.wallet!.walletPk));
                  }
                },
                child: Text(_accountLabel('Record repayment', 'تسجيل سداد')),
              ),
          ],
        );
      },
    );
  }

  final _titleFocusNode = FocusNode();

  void setSelectedTitle(String title) {
    setState(() {
      selectedTitle = title;
    });
    return;
  }

  void setSelectedColor(Color? color) {
    selectedColor = color;
    return;
  }

  void setSelectedCurrency(String currencyKey) {
    setState(() {
      selectedCurrency = currencyKey;
    });
    return;
  }

  Future<TransactionWallet?> addWallet({bool popContext = true}) async {
    if (!_detailsReady ||
        _saving ||
        (selectedTitle?.trim().isEmpty ?? true) ||
        selectedCurrency.isEmpty ||
        _accountForm.currentState?.validate() == false) {
      return null;
    }
    final openingBalance = widget.wallet == null ? initialBalance : 0.0;
    final openingNote = openingBalance == 0
        ? null
        : 'updated-total-balance'.tr() +
            '\n' +
            convertToMoney(context.read<AllWallets>(), openingBalance,
                currencyKey: selectedCurrency, decimals: selectedDecimals);
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      final draft = await createTransactionWallet();
      final saved = await database.transaction(() async {
        // SQLite upsert does not return the rowid of an updated row.
        // Use the same wallet primary key for the wallet and all its details.
        await database.createOrUpdateWallet(draft);
        await database.saveAccountDetails(
          walletPk: draft.walletPk,
          accountType: selectedAccountType,
          institutionName: institutionName,
          archived: accountArchived,
          excludeFromNetWorth: excludeFromNetWorth,
        );
        if (selectedAccountType == 'credit') {
          await database.saveCreditCardDetails(
            walletPk: draft.walletPk,
            creditLimit: creditLimit,
            statementDay: statementDay,
            dueDay: dueDay,
            minimumPayment: minimumPayment,
            minimumPercent: minimumPercent,
            lateFee: lateFee,
            aprPercent: aprPercent,
            lastFour: cardLastFour,
            linkedBankWalletFk: linkedBankWalletPk,
          );
        }
        final suffix = _newCardLastFour;
        if (widget.wallet == null &&
            _canLinkCard &&
            selectedAccountType != 'credit' &&
            suffix != null &&
            !await database.addImportCardLink(draft.walletPk, suffix)) {
          throw _CardSuffixInUse();
        }
        if (openingBalance != 0 &&
            await createCorrectionTransaction(openingBalance, draft,
                    note: openingNote) ==
                null) {
          throw StateError('Opening balance was not saved');
        }
        return database.getWalletInstance(draft.walletPk);
      });
      if (mounted) {
        walletInitial = draft;
        _initialDetails = _currentDetails;
        if (popContext) {
          savingHapticFeedback();
          popRoute(context);
        }
      }
      return saved;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(error is _CardSuffixInUse
              ? _accountLabel(
                  'These digits are already linked to another account.',
                  'الأرقام دي مرتبطة بحساب تاني.')
              : _accountLabel('Could not save the account. Try again.',
                  'تعذّر حفظ الحساب. حاول مرة أخرى.')),
        ));
      }
      return null;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<TransactionWallet> createTransactionWallet() async {
    final order = widget.wallet?.order ??
        (await database.getTotalCountOfWallets()).first ??
        0;
    return TransactionWallet(
      walletPk: _walletPk,
      iconName: widget.wallet?.iconName,
      currencyFormat: widget.wallet?.currencyFormat,
      name: selectedTitle ?? "",
      colour: toHexString(selectedColor),
      dateCreated:
          widget.wallet != null ? widget.wallet!.dateCreated : DateTime.now(),
      dateTimeModified: null,
      order: order,
      currency: selectedCurrency,
      decimals: selectedDecimals,
      homePageWidgetDisplay: widget.wallet != null
          ? widget.wallet!.homePageWidgetDisplay
          : defaultWalletHomePageWidgetDisplay,
    );
  }

  TransactionWallet? walletInitial;
  Object? _initialDetails;
  Object get _currentDetails => (
        selectedAccountType,
        institutionName,
        accountArchived,
        excludeFromNetWorth,
        creditLimit,
        statementDay,
        dueDay,
        minimumPayment,
        minimumPercent,
        lateFee,
        aprPercent,
        cardLastFour,
        _newCardLastFour,
        linkedBankWalletPk,
        initialBalance,
      );

  Future<void> _requestClose() async {
    if (_saving) return;
    final draft = await createTransactionWallet();
    if (!mounted) return;
    if (walletInitial == null) {
      popRoute(context);
      return;
    }
    if (draft.copyWith(dateCreated: walletInitial!.dateCreated) ==
            walletInitial &&
        _currentDetails == _initialDetails) {
      popRoute(context);
    } else {
      discardChangesPopup(context, forceShow: true);
    }
  }

  @override
  void initState() {
    super.initState();
    final wallet = widget.wallet;
    if (wallet != null) {
      selectedTitle = wallet.name;
      selectedCurrency = wallet.currency ?? 'usd';
      selectedDecimals = wallet.decimals;
    }
    if (FinanceDatabase.supportedAccountTypes
        .contains(widget.initialAccountType)) {
      selectedAccountType = widget.initialAccountType;
    }
    _initialDetails = _currentDetails;
    _loadAccount();
  }

  Future<void> _loadAccount() async {
    final wallet = widget.wallet;
    try {
      if (wallet != null) {
        final details = await database.getAccountDetails(wallet.walletPk);
        final type = details?['account_type'] as String? ?? 'unspecified';
        final credit = type == 'credit'
            ? await database.getCreditCardDetails(wallet.walletPk)
            : null;
        if (!mounted) return;
        selectedAccountType =
            FinanceDatabase.supportedAccountTypes.contains(type)
                ? type
                : 'unspecified';
        institutionName = details?['institution_name'] as String?;
        accountArchived = details?['archived'] == 1;
        excludeFromNetWorth = details?['exclude_from_net_worth'] == 1;
        if (credit != null) {
          creditLimit = (credit['credit_limit'] as num?)?.toDouble();
          statementDay = credit['statement_day'] as int?;
          dueDay = credit['due_day'] as int?;
          minimumPayment = (credit['minimum_payment'] as num?)?.toDouble();
          minimumPercent = (credit['minimum_percent'] as num?)?.toDouble();
          lateFee = (credit['late_fee'] as num?)?.toDouble();
          aprPercent = (credit['apr_percent'] as num?)?.toDouble();
          cardLastFour = credit['last_four'] as String?;
          linkedBankWalletPk = credit['linked_bank_wallet_fk'] as String?;
        }
        if (type == 'credit') {
          _creditSummary = database.getCreditCardSummary(wallet.walletPk);
        }
      }
      final initial = await createTransactionWallet();
      if (!mounted) return;
      setState(() {
        walletInitial = initial;
        _initialDetails = _currentDetails;
        _detailsReady = true;
      });
      widget.runWhenOpen?.call();
    } catch (_) {
      if (mounted) setState(() => _detailsFailed = true);
    }
  }

  @override
  void dispose() {
    _titleFocusNode.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void openDecimalPrecisionPopup() async {
    bool limitReached = false;
    await openBottomSheet(
      context,
      PopupFramework(
        title: "decimal-precision".tr(),
        subtitle: "decimal-precision-description".tr(),
        child: SelectAmountValue(
          enableDecimal: false,
          amountPassed: selectedDecimals.toString(),
          setSelectedAmount: (amount, amountString) {
            if (amountString == "") amount = 2;
            selectedDecimals = amount.toInt();
            if (amount > 12) {
              selectedDecimals = 12;
              limitReached = true;
            } else if (amount < 0) {
              selectedDecimals = 0;
            }
            setState(() {});
          },
          next: () async {
            popRoute(context);
          },
          nextLabel: "set-amount".tr(),
        ),
      ),
    );
    if (limitReached)
      openSnackbar(
        SnackbarMessage(
          title: "maximum-precision".tr(),
          description: "maximum-precision-description".tr(),
          icon: appStateSettings["outlinedIcons"]
              ? Symbols.decimal_increase_sharp
              : Symbols.decimal_increase_rounded,
        ),
      );
  }

  double initialBalance = 0;
  openEnterInitialBalanceBottomSheet() {
    openBottomSheet(
      context,
      fullSnap: true,
      PopupFramework(
        title: "enter-amount".tr(),
        hasPadding: false,
        underTitleSpace: false,
        child: SelectAmount(
          enableWalletPicker: false,
          padding: EdgeInsetsDirectional.symmetric(horizontal: 18),
          onlyShowCurrencyIcon: true,
          selectedWalletPk: appStateSettings["selectedWalletPk"],
          amountPassed: initialBalance.toString(),
          setSelectedAmount: (amount, _) {
            setState(() {
              initialBalance = amount;
            });
          },
          next: () async {
            popRoute(context);
          },
          currencyKey: selectedCurrency,
          nextLabel: "set-amount".tr(),
          allowZero: true,
          decimals: selectedDecimals == 2 ? null : selectedDecimals,
        ),
      ),
    );
  }

  bool get _canLinkCard => const {'bank', 'debit', 'credit', 'prepaid'}
      .contains(selectedAccountType);

  Future<void> _chooseInstitution() async {
    final result = await pickCashuInstitution(context, institutionName,
        mobileWallet: selectedAccountType == 'ewallet');
    if (result == null || !mounted) return;
    setState(() {
      institutionName = result.isEmpty ? null : result;
      if (result.isNotEmpty && (selectedTitle?.trim().isEmpty ?? true)) {
        selectedTitle = result;
        _nameController.text = result;
      }
    });
  }

  late final _nameController = TextEditingController(text: widget.wallet?.name);

  Future<String?> _editValue(
    String title,
    String initial, {
    required String? Function(String?) validate,
    bool decimal = false,
    int? maxLength,
  }) async {
    var entered = initial;
    final key = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (context) {
        void save() {
          if (key.currentState?.validate() == true)
            Navigator.pop(context, entered.trim());
        }

        return AlertDialog(
          backgroundColor: CashuColors(context).panel,
          scrollable: true,
          title: Text(title),
          content: Form(
            key: key,
            child: TextFormField(
              initialValue: initial,
              autofocus: true,
              maxLength: maxLength,
              keyboardType: TextInputType.numberWithOptions(decimal: decimal),
              decoration: cashuInput(context, title),
              onChanged: (value) =>
                  entered = FinancialMessageParser.normalize(value),
              validator: validate,
              onFieldSubmitted: (_) => save(),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('cancel'.tr())),
            FilledButton(onPressed: save, child: Text('save'.tr())),
          ],
        );
      },
    );
  }

  Future<void> _editCardSuffix() async {
    final credit = selectedAccountType == 'credit';
    final current = credit ? cardLastFour : _newCardLastFour;
    final result = await _editValue(
      _accountLabel('Last four digits', 'آخر ٤ أرقام'),
      current ?? '',
      maxLength: 4,
      validate: (value) {
        final digits = FinancialMessageParser.normalize(value?.trim() ?? '');
        return digits.isEmpty || RegExp(r'^[0-9]{4}$').hasMatch(digits)
            ? null
            : _accountLabel('Use four digits', 'أدخل أربعة أرقام');
      },
    );
    if (!mounted || result == null) return;
    setState(() {
      final suffix = result.isEmpty ? null : result;
      if (credit) {
        cardLastFour = suffix;
      } else {
        _newCardLastFour = suffix;
      }
    });
  }

  Future<void> _chooseDay({required bool statement}) async {
    final title = statement
        ? _accountLabel('Statement day', 'يوم كشف الحساب')
        : _accountLabel('Payment due day', 'يوم الاستحقاق');
    final selected = statement ? statementDay : dueDay;
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: SizedBox(
            width: 310,
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (var day = 1; day <= 31; day++)
                  ChoiceChip(
                    label: Text(
                        MaterialLocalizations.of(context).formatDecimal(day)),
                    selected: selected == day,
                    onSelected: (_) => Navigator.pop(context, day),
                  ),
              ],
            )),
        actions: [
          if (selected != null)
            TextButton(
              onPressed: () => Navigator.pop(context, 0),
              child: Text(_accountLabel('Clear day', 'امسح اليوم')),
            ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('cancel'.tr())),
        ],
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      final day = result == 0 ? null : result;
      if (statement) {
        statementDay = day;
      } else {
        dueDay = day;
      }
    });
  }

  Widget _optionalAmount(String title, double? raw, ValueChanged<double?> set,
          {double? max, String? suffix}) =>
      CashuActionRow(
        icon: Icons.tune_rounded,
        title: title,
        detail: raw == null
            ? _accountLabel('Optional', 'اختياري')
            : '$raw${suffix ?? ''}',
        onTap: () async {
          final result = await _editValue(title, raw?.toString() ?? '',
              decimal: true,
              validate: (value) => _validateCreditNumber(value, max: max));
          if (result == null || !mounted) return;
          setState(() => set(double.tryParse(result)));
        },
      );

  @override
  Widget build(BuildContext context) {
    final colors = CashuColors(context);
    final title = widget.wallet != null
        ? 'edit-account'.tr()
        : widget.initialAccountType == 'credit'
            ? _accountLabel('Add credit card', 'إضافة بطاقة ائتمان')
            : 'add-account'.tr();
    if (!_detailsReady) {
      return PageFramework(
        title: title,
        backgroundColor: colors.canvas,
        listWidgets: [
          if (_detailsFailed)
            Center(
                child: TextButton(
              onPressed: () {
                setState(() => _detailsFailed = false);
                _loadAccount();
              },
              child: Text(
                  _accountLabel('Retry loading account', 'أعد تحميل الحساب')),
            ))
          else
            const LinearProgressIndicator(),
        ],
      );
    }

    final replacing = widget.wallet != null;
    final credit = selectedAccountType == 'credit';
    final currency = selectedCurrency.toUpperCase();
    final accounts = context.watch<AllWallets>();
    final typeName = _accountLabel(
      accountTypeNames[selectedAccountType]!.$1,
      accountTypeNames[selectedAccountType]!.$2,
    );
    final provider = institutionName ?? _accountLabel('Optional', 'اختياري');
    final isWallet = selectedAccountType == 'ewallet';
    final currencyName =
        currenciesJSON[selectedCurrency]?['Currency'] as String?;
    String dayText(int? day) => day == null
        ? _accountLabel('Choose a day', 'اختار اليوم')
        : MaterialLocalizations.of(context).formatDecimal(day);
    return WillPopScope(
      onWillPop: () async {
        await _requestClose();
        return false;
      },
      child: PageFramework(
        resizeToAvoidBottomInset: true,
        dragDownToDismiss: true,
        horizontalPaddingConstrained: true,
        backgroundColor: colors.canvas,
        title: title,
        onBackButton: _requestClose,
        onDragDownToDismiss: _requestClose,
        staticOverlay: Align(
          alignment: AlignmentDirectional.bottomCenter,
          child: SaveBottomButton(
            label: (selectedTitle?.trim().isEmpty ?? true)
                ? 'set-name'.tr()
                : replacing
                    ? 'save-changes'.tr()
                    : 'add-account'.tr(),
            onTap: () async {
              if (selectedTitle?.trim().isEmpty ?? true) {
                _titleFocusNode.requestFocus();
              } else {
                await addWallet();
              }
            },
            disabled: _saving || selectedCurrency.isEmpty,
          ),
        ),
        listWidgets: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 78),
            child: Form(
              key: _accountForm,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CashuGreenPanel(
                    child: Row(children: [
                      Icon(cashuAccountIcon(selectedAccountType),
                          color: const Color(0xffb4edb8), size: 30),
                      const SizedBox(width: 12),
                      Flexible(
                          child: Text(typeName,
                              style: const TextStyle(
                                  color: Color(0xffeff8f0),
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800))),
                    ]),
                  ),
                  CashuSectionTitle(
                      _accountLabel('Account basics', 'بيانات الحساب')),
                  CashuPanel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _nameController,
                            focusNode: _titleFocusNode,
                            decoration: cashuInput(context,
                                _accountLabel('Account name', 'اسم الحساب')),
                            onChanged: setSelectedTitle,
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: selectedAccountType,
                            decoration: cashuInput(context,
                                _accountLabel('Account type', 'نوع الحساب')),
                            isExpanded: true,
                            items: [
                              for (final entry in accountTypeNames.entries)
                                DropdownMenuItem(
                                    value: entry.key,
                                    child: Text(_accountLabel(
                                        entry.value.$1, entry.value.$2))),
                            ],
                            onChanged: (value) {
                              if (value != null)
                                setState(() => selectedAccountType = value);
                            },
                          ),
                          const SizedBox(height: 7),
                          CashuActionRow(
                            icon: Icons.payments_outlined,
                            title: _accountLabel('Currency', 'العملة'),
                            detail: currencyName == null
                                ? currency
                                : '$currency · $currencyName',
                            onTap: () async {
                              final code = await pickCashuCurrency(
                                  context, selectedCurrency);
                              if (mounted && code != null)
                                setSelectedCurrency(code);
                            },
                          ),
                          if (!replacing)
                            CashuActionRow(
                              icon: Icons.account_balance_wallet_outlined,
                              title: _accountLabel(
                                  'Starting balance', 'الرصيد الافتتاحي'),
                              detail: convertToMoney(accounts, initialBalance,
                                  currencyKey: selectedCurrency,
                                  decimals: selectedDecimals),
                              onTap: openEnterInitialBalanceBottomSheet,
                            ),
                        ]),
                  ),
                  if (credit) ...[
                    CashuSectionTitle(
                        _accountLabel('Credit card', 'بطاقة الائتمان')),
                    CashuPanel(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          TextFormField(
                            initialValue: creditLimit?.toString(),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: cashuInput(context,
                                _accountLabel('Credit limit', 'الحد الائتماني'),
                                suffix: currency),
                            validator: _validateCreditNumber,
                            onChanged: (value) => creditLimit = double.tryParse(
                                FinancialMessageParser.normalize(value.trim())),
                          ),
                          CashuActionRow(
                              icon: Icons.event_outlined,
                              title: _accountLabel(
                                  'Statement day', 'يوم كشف الحساب'),
                              detail: dayText(statementDay),
                              onTap: () => _chooseDay(statement: true)),
                          CashuActionRow(
                              icon: Icons.today_outlined,
                              title: _accountLabel(
                                  'Payment due day', 'يوم الاستحقاق'),
                              detail: dayText(dueDay),
                              onTap: () => _chooseDay(statement: false)),
                        ])),
                  ],
                  const SizedBox(height: 12),
                  CashuOptionSection(
                    icon: isWallet
                        ? Icons.phone_iphone_outlined
                        : Icons.account_balance_outlined,
                    title: _accountLabel(
                        'Bank and card messages', 'البنك ورسائل البطاقات'),
                    detail: institutionName,
                    children: [
                      CashuActionRow(
                          icon: Icons.domain_outlined,
                          title: isWallet
                              ? _accountLabel('Wallet provider', 'مزود المحفظة')
                              : _accountLabel(
                                  'Bank or provider', 'البنك أو التطبيق'),
                          detail: provider,
                          onTap: _chooseInstitution),
                      if (credit || (!replacing && _canLinkCard))
                        CashuActionRow(
                            icon: Icons.pin_outlined,
                            title: _accountLabel(
                                'Last four digits', 'آخر ٤ أرقام'),
                            detail:
                                (credit ? cardLastFour : _newCardLastFour) ??
                                    _accountLabel('Optional', 'اختياري'),
                            onTap: _editCardSuffix),
                      if (replacing && !accountArchived)
                        CashuActionRow(
                            icon: Icons.link,
                            title: _accountLabel(
                                'Link card messages', 'ربط رسائل البطاقات'),
                            onTap: () => showDialog<void>(
                                  context: context,
                                  builder: (_) => ImportCardLinks(
                                      initialWalletPk: widget.wallet!.walletPk),
                                )),
                    ],
                  ),
                  if (credit) ...[
                    const SizedBox(height: 10),
                    CashuOptionSection(
                      icon: Icons.receipt_long_outlined,
                      title:
                          _accountLabel('Repayment and fees', 'السداد والرسوم'),
                      children: [
                        _creditAccountDetails(),
                        _optionalAmount(
                            _accountLabel('Fixed minimum or floor',
                                'مبلغ الحد الأدنى الثابت'),
                            minimumPayment,
                            (v) => minimumPayment = v),
                        _optionalAmount(
                            _accountLabel('Minimum as % of statement',
                                'نسبة الحد الأدنى من الكشف'),
                            minimumPercent,
                            (v) => minimumPercent = v,
                            max: 100,
                            suffix: '%'),
                        _optionalAmount(
                            _accountLabel('Flat late fee (estimate)',
                                'رسوم التأخير الثابتة (تقديرية)'),
                            lateFee,
                            (v) => lateFee = v,
                            max: 999999999999),
                        _optionalAmount(
                            _accountLabel('APR %', 'معدل الفائدة السنوي %'),
                            aprPercent,
                            (v) => aprPercent = v,
                            suffix: '%'),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  CashuOptionSection(
                    icon: Icons.tune_rounded,
                    title:
                        _accountLabel('Account preferences', 'تفضيلات الحساب'),
                    children: [
                      SizedBox(
                          height: 65,
                          child: SelectColor(
                              horizontalList: true,
                              selectedColor: selectedColor,
                              setSelectedColor: setSelectedColor)),
                      CashuActionRow(
                          icon: Symbols.decimal_increase_rounded,
                          title: 'decimal-precision'.tr(),
                          detail: MaterialLocalizations.of(context)
                              .formatDecimal(selectedDecimals),
                          onTap: openDecimalPrecisionPopup),
                      SwitchListTile(
                        title: Text(_accountLabel('Exclude from net worth',
                            'استبعاد من صافي الثروة')),
                        value: excludeFromNetWorth,
                        onChanged: (v) =>
                            setState(() => excludeFromNetWorth = v),
                      ),
                      SwitchListTile(
                        title: Text(
                            _accountLabel('Archive account', 'أرشفة الحساب')),
                        value: accountArchived,
                        onChanged: (v) => setState(() => accountArchived = v),
                      ),
                    ],
                  ),
                  if (replacing) ...[
                    const SizedBox(height: 10),
                    CashuOptionSection(
                      icon: Icons.settings_outlined,
                      title: _accountLabel('Manage account', 'إدارة الحساب'),
                      children: [
                        CashuActionRow(
                            icon: Icons.edit_outlined,
                            title: 'correct-total-balance'.tr(),
                            onTap: () async {
                              final wallet = await addWallet(popContext: false);
                              if (!mounted || wallet == null) return;
                              openBottomSheet(
                                  context,
                                  fullSnap: true,
                                  CorrectBalancePopup(wallet: wallet));
                            }),
                        if (accounts.list.length > 1)
                          CashuActionRow(
                              icon: Icons.compare_arrows,
                              title: 'transfer-balance'.tr(),
                              onTap: () async {
                                final wallet =
                                    await addWallet(popContext: false);
                                if (!mounted || wallet == null) return;
                                openBalanceTransfer(
                                    context,
                                    TransferBalancePage(
                                        wallet: wallet,
                                        allowEditWallet: false));
                              }),
                        if (widget.routesToPopAfterDelete !=
                            RoutesToPopAfterDelete.PreventDelete)
                          CashuActionRow(
                              icon: Icons.merge_outlined,
                              title: 'merge-account'.tr(),
                              onTap: () => mergeWalletPopup(context,
                                  walletOriginal: widget.wallet!,
                                  routesToPopAfterDelete:
                                      widget.routesToPopAfterDelete)),
                        if (widget.wallet!.walletPk != '0' &&
                            widget.routesToPopAfterDelete !=
                                RoutesToPopAfterDelete.PreventDelete)
                          CashuActionRow(
                              icon: Icons.delete_outline,
                              title: 'delete-account'.tr(),
                              onTap: () => deleteWalletPopup(context,
                                  wallet: widget.wallet!,
                                  routesToPopAfterDelete:
                                      widget.routesToPopAfterDelete)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardSuffixInUse implements Exception {}

class CorrectBalancePopup extends StatefulWidget {
  const CorrectBalancePopup({
    required this.wallet,
    this.showAllEditDetails = false,
    super.key,
  });
  final TransactionWallet wallet;
  final bool showAllEditDetails;

  @override
  State<CorrectBalancePopup> createState() => _CorrectBalancePopupState();
}

class _CorrectBalancePopupState extends State<CorrectBalancePopup> {
  double enteredAmount = 0;
  bool isNegative = false;
  TimeOfDay? selectedTime = null;
  DateTime? selectedDateTime = null;
  String selectedTitle = "";

  @override
  Widget build(BuildContext context) {
    Widget editTransferDetails = Column(
      children: [
        TextInput(
          icon: appStateSettings["outlinedIcons"]
              ? Icons.title_outlined
              : Icons.title_rounded,
          autoFocus: widget.showAllEditDetails == false,
          onChanged: (text) async {
            selectedTitle = text;
          },
          onEditingComplete: widget.showAllEditDetails == true
              ? null
              : () {
                  if (widget.showAllEditDetails) maybePopRoute(context);
                },
          initialValue: selectedTitle,
          labelText: "transfer-balance".tr(),
          padding: EdgeInsetsDirectional.only(bottom: 13),
        ),
        DateButton(
          internalPadding: EdgeInsetsDirectional.only(end: 5),
          initialSelectedDate: selectedDateTime ?? DateTime.now(),
          initialSelectedTime: TimeOfDay(
              hour: selectedDateTime?.hour ?? TimeOfDay.now().hour,
              minute: selectedDateTime?.minute ?? TimeOfDay.now().minute),
          setSelectedDate: (date) {
            selectedDateTime = date;
          },
          setSelectedTime: (time) {
            selectedDateTime = (selectedDateTime ?? DateTime.now())
                .copyWith(hour: time.hour, minute: time.minute);
          },
        ),
      ],
    );

    return PopupFramework(
      title: "correct-balance".tr(),
      subtitle: widget.wallet.name,
      underTitleSpace: false,
      outsideExtraWidget: widget.showAllEditDetails
          ? null
          : OutsideExtraWidgetIconButton(
              iconData: appStateSettings["outlinedIcons"]
                  ? Icons.edit_outlined
                  : Icons.edit_rounded,
              onPressed: () async {
                await openBottomSheet(
                  context,
                  popupWithKeyboard: true,
                  PopupFramework(
                    child: editTransferDetails,
                    title: "transaction-details".tr(),
                  ),
                );
                setState(() {});
              },
            ),
      child: StreamBuilder<double?>(
        stream: database.watchTotalOfWalletNoConversion(
          widget.wallet.walletPk,
        ),
        builder: (context, snapshot) {
          double totalWalletAmount = snapshot.data ?? 0;
          return Column(
            children: [
              if (widget.showAllEditDetails)
                Padding(
                  padding: const EdgeInsetsDirectional.only(bottom: 15),
                  child: editTransferDetails,
                ),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextFont(
                    autoSizeText: true,
                    maxLines: 1,
                    minFontSize: 16,
                    text: convertToMoney(
                      Provider.of<AllWallets>(context),
                      totalWalletAmount,
                      currencyKey: widget.wallet.currency,
                      decimals: widget.wallet.decimals,
                    ),
                    textAlign: TextAlign.center,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                  ),
                  Padding(
                    padding:
                        const EdgeInsetsDirectional.symmetric(horizontal: 10),
                    child: Icon(
                      appStateSettings["outlinedIcons"]
                          ? Icons.arrow_forward_outlined
                          : Icons.arrow_forward_rounded,
                    ),
                  ),
                  AnimatedSizeSwitcher(
                    clipBehavior: Clip.none,
                    child: TextFont(
                      key: ValueKey(enteredAmount.toString()),
                      autoSizeText: true,
                      maxLines: 1,
                      minFontSize: 16,
                      text: convertToMoney(
                        Provider.of<AllWallets>(context),
                        enteredAmount,
                        currencyKey: widget.wallet.currency,
                        decimals: widget.wallet.decimals,
                        forceAbsoluteZero: false,
                      ),
                      textAlign: TextAlign.center,
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 5),
              Builder(builder: (context) {
                double difference = (enteredAmount - totalWalletAmount);
                return AmountWithColorAndArrow(
                  showIncomeArrow: true,
                  totalSpent: difference,
                  fontSize: 20,
                  iconSize: 24,
                  iconWidth: 15,
                  countNumberDuration: Duration(milliseconds: 300),
                  currencyKey: widget.wallet.currency,
                );
              }),
              SizedBox(height: 8),
              SelectAmount(
                // Rerender when has data, so that the initialValue of negative-amount if correct
                // Also render if no data, because that means the wallet is empty
                // We still want users to be able to correct the amount
                key: ValueKey(snapshot.hasData == false),
                extraWidgetAboveNumbers: SettingsContainerSwitch(
                  title: "negative-amount".tr(),
                  onSwitched: (value) {
                    setState(() {
                      isNegative = value;
                      if (isNegative == true)
                        enteredAmount = enteredAmount.abs() * -1;
                      else
                        enteredAmount = enteredAmount.abs();
                    });
                  },
                  enableBorderRadius: true,
                  initialValue: totalWalletAmount < 0,
                  syncWithInitialValue: false,
                  runOnSwitchedInitially: true,
                  icon: appStateSettings["outlinedIcons"]
                      ? Icons.exposure_outlined
                      : Icons.exposure_rounded,
                ),
                showEnteredNumber: false,
                amountPassed: "0",
                setSelectedAmount: (amount, calculation) {
                  setState(() {
                    if (isNegative == true)
                      enteredAmount = amount.abs() * -1;
                    else
                      enteredAmount = amount.abs();
                  });
                },
                allowZero: true,
                next: () async {
                  await correctWalletBalance(
                    context,
                    enteredAmount - totalWalletAmount,
                    enteredAmount,
                    widget.wallet,
                    selectedDateTime,
                    selectedTitle,
                  );
                  savingHapticFeedback();
                  popRoute(context);
                },
                nextLabel: "update-total-balance".tr(),
              ),
            ],
          );
        },
      ),
    );
  }
}

Future<bool> correctWalletBalance(
    BuildContext context,
    double differenceAmount,
    double newAmount,
    TransactionWallet wallet,
    DateTime? dateTime,
    String title) async {
  String transferString = wallet.name +
      ": " +
      convertToMoney(
        Provider.of<AllWallets>(context, listen: false),
        newAmount,
        currencyKey: wallet.currency,
        decimals: wallet.decimals,
      );

  String note = "updated-total-balance".tr() + "\n" + transferString;

  await createCorrectionTransaction(
    differenceAmount,
    wallet,
    note: note,
    dateTime: dateTime,
    title: title,
  );

  openSnackbar(
    SnackbarMessage(
      title: "updated-total-balance".tr(),
      description: transferString,
      icon: appStateSettings["outlinedIcons"]
          ? Icons.library_add_outlined
          : Icons.library_add_rounded,
    ),
  );

  return true;
}

Future<TransactionCategory> initializeBalanceCorrectionCategory() async {
  try {
    return await database.getCategory("0").$2;
  } catch (e) {
    print(
        e.toString() + "- creating default category amount balancing category");
    int numberOfCategories =
        (await database.getTotalCountOfCategories())[0] ?? 0;

    await database.createOrUpdateCategory(
      insert: false,
      updateSharedEntry: false,
      TransactionCategory(
        categoryPk: "0",
        name: "default-category-account-amount-balancing".tr(),
        colour: toHexString(Colors.blueGrey),
        iconName: "charts.png",
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: numberOfCategories,
        income: false,
      ),
    );
    return await database.getCategory("0").$2;
  }
}

Future<String?> createCorrectionTransaction(
  double amount,
  TransactionWallet wallet, {
  String? note,
  DateTime? dateTime,
  String? title,
  String? pairedTransactionFk,
  String? objectiveLoanPk,
}) async {
  await initializeBalanceCorrectionCategory();

  int? rowId = await database.createOrUpdateTransaction(
    insert: true,
    updateSharedEntry: false,
    Transaction(
      pairedTransactionFk: pairedTransactionFk,
      transactionPk: "-1",
      name: title ?? "",
      amount: amount,
      note: note ?? "",
      categoryFk: "0",
      walletFk: wallet.walletPk,
      dateCreated: dateTime ?? DateTime.now(),
      income: amount > 0,
      paid: true,
      skipPaid: false,
      objectiveLoanFk: objectiveLoanPk,
    ),
  );
  if (rowId != null) {
    final Transaction transactionJustAdded =
        await database.getTransactionFromRowId(rowId);
    return transactionJustAdded.transactionPk;
  }
  return null;
}

Future<bool> openBalanceTransfer(
        BuildContext context, TransferBalancePage page) async =>
    await pushRoute(context, page) == true;

class TransferBalancePage extends StatefulWidget {
  const TransferBalancePage({
    super.key,
    this.wallet,
    this.allowEditWallet = false,
    this.showAllEditDetails = false,
    this.initialAmount,
    this.initialAmountWallet,
    this.initialTarget,
    this.initialDate,
    this.initialTitle,
    this.initialObjectiveLoanPk,
    this.initialIsNegative,
    this.statementRepayment,
  });

  final TransactionWallet? wallet;
  final bool allowEditWallet;
  final bool showAllEditDetails;
  final double? initialAmount;
  final TransactionWallet? initialAmountWallet;
  final TransactionWallet? initialTarget;
  final DateTime? initialDate;
  final String? initialTitle;
  final String? initialObjectiveLoanPk;
  final bool? initialIsNegative;
  final CardStatementRepayment? statementRepayment;

  @override
  State<TransferBalancePage> createState() => _TransferBalancePageState();
}

class _TransferBalancePageState extends State<TransferBalancePage> {
  late final _amount = TextEditingController(
    text: widget.initialAmount?.abs().toString() ?? '',
  );
  late final _title = TextEditingController(text: widget.initialTitle ?? '');
  late final _wallets = database.watchAllWallets().asyncMap((wallets) async {
    final details = await database.getAllAccountDetails();
    return wallets
        .where((wallet) => details[wallet.walletPk]?['archived'] != 1)
        .toList();
  });
  late DateTime? _date = widget.initialDate;
  late final _openedAt = DateTime.now();
  late final bool _reverseOnOpen = widget.initialIsNegative == true;
  late String? _sourcePk =
      (_reverseOnOpen ? widget.initialTarget : widget.wallet)?.walletPk;
  late String? _targetPk =
      (_reverseOnOpen ? widget.wallet : widget.initialTarget)?.walletPk;
  late String? _explicitCurrency =
      widget.initialAmountWallet?.currency?.toLowerCase();
  bool _instaPay = false;
  bool _saving = false;
  String? _error;

  bool get _fixedRepayment => widget.statementRepayment != null;
  bool get _arabic => Localizations.localeOf(context).languageCode == 'ar';
  String _label(String en, String ar) => _arabic ? ar : en;

  double? get _principal {
    final locale = Localizations.localeOf(context).toString();
    if (_amount.text.contains('٬')) return null;
    var normalized = FinancialMessageParser.normalize(_amount.text.trim());
    if (NumberFormat.decimalPattern(locale).symbols.DECIMAL_SEP == ',') {
      normalized = normalized.replaceAll(',', '.');
    }
    if (!RegExp(r'^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$').hasMatch(normalized)) {
      return null;
    }
    final parsed = double.tryParse(normalized);
    return parsed != null && parsed > 0 && parsed <= 999999999999
        ? parsed
        : null;
  }

  @override
  void dispose() {
    _amount.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _save(
    TransactionWallet source,
    TransactionWallet target,
    String? currency,
    double principal, {
    required bool instaPay,
  }) async {
    if (_saving) return;
    double? ratioTo(TransactionWallet wallet) {
      final destination = wallet.currency?.toLowerCase();
      return currency == destination
          ? 1
          : strictCurrencyRatio(currency, destination);
    }

    final fromRatio = ratioTo(source);
    final toRatio = ratioTo(target);
    if (fromRatio == null || toRatio == null) {
      setState(() => _error = _label(
            'Exchange rate unavailable for these accounts.',
            'سعر الصرف بين الحسابين غير متاح.',
          ));
      return;
    }
    if (instaPay && instaPayTransferFee(principal) == null) {
      setState(() => _error = _label(
            'Use up to two decimal places for InstaPay.',
            'اكتب مبلغ إنستاباي بمنزلتين عشريتين بحد أقصى.',
          ));
      return;
    }
    final debitAmount = principal * fromRatio;
    final creditAmount = principal * toRatio;
    if (!debitAmount.isFinite ||
        !creditAmount.isFinite ||
        debitAmount <= 0 ||
        creditAmount <= 0 ||
        debitAmount > 999999999999 ||
        creditAmount > 999999999999) {
      setState(() => _error = 'invalid-amount'.tr());
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    final when = _date ?? _openedAt;
    final debitId = uuid.v4();
    final creditId = uuid.v4();
    final title = _title.text.trim();
    final arabic = _arabic;
    final note =
        "transferred-balance".tr() + '\n' + source.name + ' → ' + target.name;
    final debit = Transaction(
      transactionPk: debitId,
      pairedTransactionFk: creditId,
      name: title.isEmpty ? '${source.name} ${"transfer-out".tr()}' : title,
      amount: -debitAmount,
      note: note,
      categoryFk: '0',
      walletFk: source.walletPk,
      dateCreated: when,
      income: false,
      paid: true,
      skipPaid: false,
      objectiveLoanFk: widget.initialObjectiveLoanPk,
    );
    final credit = Transaction(
      transactionPk: creditId,
      pairedTransactionFk: debitId,
      name: title.isEmpty ? '${target.name} ${"transfer-in".tr()}' : title,
      amount: creditAmount,
      note: note,
      categoryFk: '0',
      walletFk: target.walletPk,
      dateCreated:
          _fixedRepayment ? when : when.add(const Duration(seconds: 1)),
      income: true,
      paid: true,
      skipPaid: false,
    );
    final idempotencyKey = [
      instaPay ? 'instapay-transfer' : 'transfer',
      source.walletPk,
      target.walletPk,
      when.microsecondsSinceEpoch,
      (-debitAmount).toStringAsPrecision(15),
      creditAmount.toStringAsPrecision(15),
    ].join(':');

    try {
      await initializeBalanceCorrectionCategory();
      final repayment = widget.statementRepayment;
      final saved = repayment == null
          ? await database.saveAtomicLocalTransfer(debit, credit,
              idempotencyKey: idempotencyKey,
              instaPay: instaPay,
              arabicFeeLabel: arabic)
          : await saveCardStatementRepayment(database, repayment, debit, credit,
              idempotencyKey: idempotencyKey);
      if (!mounted) return;
      if (saved == null) {
        setState(() => _error = _label(
              'The statement changed. Reopen it before recording repayment.',
              'الكشف اتغيّر. افتحه من جديد قبل تسجيل السداد.',
            ));
        return;
      }
      if (saved) {
        openSnackbar(SnackbarMessage(
          title: 'transferred-balance'.tr(),
          description: '${source.name} → ${target.name}',
          icon: Icons.compare_arrows,
        ));
        savingHapticFeedback();
      }
      Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted)
        setState(() => _error = _label(
              'Could not save the transfer. Check both accounts and try again.',
              'تعذّر حفظ التحويل. راجع الحسابين وحاول مرة أخرى.',
            ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _accountField({
    required String label,
    required List<TransactionWallet> wallets,
    required TransactionWallet? selected,
    required TransactionWallet? other,
    required ValueChanged<String?> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey((label, selected?.walletPk)),
            initialValue: selected?.walletPk,
            isExpanded: true,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.account_balance_wallet_outlined),
              labelText: label,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final wallet in wallets)
                DropdownMenuItem(
                  value: wallet.walletPk,
                  enabled: wallet.walletPk != other?.walletPk,
                  child: Text(
                    [
                      wallet.name,
                      if (wallet.currency != null)
                        wallet.currency!.toUpperCase()
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _fixedRepayment || _saving ? null : onChanged,
          ),
        ),
        if (widget.allowEditWallet && selected != null && !_saving)
          IconButton(
            tooltip: 'edit-account'.tr(),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => pushRoute(
                context,
                AddWalletPage(
                  wallet: selected,
                  routesToPopAfterDelete: RoutesToPopAfterDelete.PreventDelete,
                )),
          ),
      ],
    );
  }

  void _openCalculator(String? currency) {
    openBottomSheet(
      context,
      PopupFramework(
        title: 'enter-amount'.tr(),
        child: SelectAmount(
          amountPassed: _amount.text,
          currencyKey: currency,
          setSelectedAmount: (amount, _) => setState(() {
            _amount.text = amount.abs().toString();
            _error = null;
          }),
          next: () => popRoute(context),
          nextLabel: 'set-amount'.tr(),
        ),
      ),
    );
  }

  Widget _transferForm(List<TransactionWallet> wallets) {
    final indexed = {for (final wallet in wallets) wallet.walletPk: wallet};
    final allWallets = AllWallets(list: wallets, indexedByPk: indexed);
    final current =
        indexed[appStateSettings['selectedWalletPk']] ?? wallets.firstOrNull;
    final target = indexed[_targetPk];
    final source = indexed[_sourcePk] ??
        (_sourcePk == null &&
                !_reverseOnOpen &&
                !_fixedRepayment &&
                current != target
            ? current
            : null);
    final currency = _explicitCurrency ??
        source?.currency?.toLowerCase() ??
        target?.currency?.toLowerCase();
    final currencies = {
      for (final wallet in wallets)
        if (wallet.currency != null) wallet.currency!.toLowerCase(),
    };
    final canUseInstaPay = !_fixedRepayment &&
        widget.initialObjectiveLoanPk == null &&
        isInstaPayCurrency(source?.currency) &&
        isInstaPayCurrency(target?.currency);
    final useInstaPay =
        canUseInstaPay && isInstaPayCurrency(currency) && _instaPay;
    final principal = _principal;
    final fee = useInstaPay && principal != null
        ? instaPayTransferFee(principal)
        : null;
    String money(double amount) => convertToMoney(
          allWallets,
          amount,
          currencyKey: currency,
          addCurrencyName: true,
        );
    final scheme = Theme.of(context).colorScheme;

    if (wallets.length < 2 ||
        (_fixedRepayment && (source == null || target == null))) {
      return Center(
          child: Padding(
        padding: const EdgeInsetsDirectional.all(24),
        child: Text(
            _label(
              'Two active accounts are needed for a transfer.',
              'التحويل محتاج حسابين نشطين.',
            ),
            textAlign: TextAlign.center),
      ));
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 20, 12),
            children: [
              CashuPanel(
                child: Column(
                  children: [
                    _accountField(
                      label: _label('From account', 'من حساب'),
                      wallets: wallets,
                      selected: source,
                      other: target,
                      onChanged: (id) => setState(() {
                        _sourcePk = id;
                        _error = null;
                      }),
                    ),
                    if (!_fixedRepayment)
                      IconButton(
                        tooltip: _label('Swap accounts', 'بدّل الحسابين'),
                        icon: const Icon(Icons.swap_vert_rounded),
                        onPressed: _saving || source == null || target == null
                            ? null
                            : () => setState(() {
                                  _sourcePk = target.walletPk;
                                  _targetPk = source.walletPk;
                                  _error = null;
                                }),
                      )
                    else
                      const SizedBox(height: 12),
                    _accountField(
                      label: _label('To account', 'إلى حساب'),
                      wallets: wallets,
                      selected: target,
                      other: source,
                      onChanged: (id) => setState(() {
                        _targetPk = id;
                        _error = null;
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _amount,
                enabled: !_saving,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: _label('Transfer amount', 'مبلغ التحويل'),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _label('Calculator', 'الحاسبة'),
                    icon: const Icon(Icons.calculate_outlined),
                    onPressed: _saving ? null : () => _openCalculator(currency),
                  ),
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
              if (!_fixedRepayment && currencies.length > 1) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey(('transfer-currency', currency)),
                  initialValue: currencies.contains(currency) ? currency : null,
                  decoration:
                      InputDecoration(labelText: 'select-currency'.tr()),
                  items: [
                    for (final code in currencies)
                      DropdownMenuItem(
                          value: code, child: Text(code.toUpperCase())),
                  ],
                  onChanged: _saving
                      ? null
                      : (code) => setState(() {
                            _explicitCurrency = code;
                            _error = null;
                          }),
                ),
              ] else if (currency != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: 8, start: 12),
                  child: Text(currency.toUpperCase()),
                ),
              if (canUseInstaPay)
                SwitchListTile(
                  contentPadding:
                      const EdgeInsetsDirectional.symmetric(horizontal: 12),
                  title:
                      Text(_label('InstaPay transfer', 'تحويل عبر إنستاباي')),
                  subtitle: Text(fee == null
                      ? _label(
                          '0.1%, EGP 0.50 to 20', '٠٫١٪، من ٥٠ قرش لحد ٢٠ جنيه')
                      : _label(
                          'Fee ${money(fee)} · Total debit ${money(principal! + fee)}',
                          'الرسوم ${money(fee)} · إجمالي الخصم ${money(principal! + fee)}')),
                  value: useInstaPay,
                  onChanged: _saving
                      ? null
                      : (enabled) => setState(() {
                            _instaPay = enabled;
                            if (enabled) _explicitCurrency = 'egp';
                            _error = null;
                          }),
                ),
              CashuOptionSection(
                icon: Icons.tune_rounded,
                title: _label('Date and reference', 'التاريخ والمرجع'),
                initiallyExpanded: widget.showAllEditDetails,
                children: [
                  TextField(
                    controller: _title,
                    enabled: !_saving,
                    decoration: InputDecoration(labelText: 'title'.tr()),
                  ),
                  const SizedBox(height: 12),
                  DateButton(
                    initialSelectedDate: _date ?? _openedAt,
                    initialSelectedTime:
                        TimeOfDay.fromDateTime(_date ?? _openedAt),
                    setSelectedDate: (date) => _date = date,
                    setSelectedTime: (time) => _date = (_date ?? _openedAt)
                        .copyWith(hour: time.hour, minute: time.minute),
                  ),
                ],
              ),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: 12),
                  child: Text(error, style: TextStyle(color: scheme.error)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ||
                      source == null ||
                      target == null ||
                      principal == null
                  ? null
                  : () => _save(source, target, currency, principal,
                      instaPay: useInstaPay),
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.compare_arrows),
              label: Text(_label('Save transfer', 'حفظ التحويل')),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CashuColors(context).canvas,
      appBar: AppBar(
        backgroundColor: CashuColors(context).canvas,
        title: Text('transfer-balance'.tr()),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: StreamBuilder<List<TransactionWallet>>(
              stream: _wallets,
              builder: (context, snapshot) {
                if (snapshot.hasError)
                  return Center(
                      child: Text(_label(
                    'Could not load accounts.',
                    'تعذّر تحميل الحسابات.',
                  )));
                final wallets = snapshot.data;
                if (wallets == null)
                  return const Center(child: CircularProgressIndicator());
                return _transferForm(wallets);
              },
            ),
          ),
        ),
      ),
    );
  }
}
