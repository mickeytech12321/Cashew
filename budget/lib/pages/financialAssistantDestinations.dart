import 'package:budget/pages/accountsPage.dart';
import 'package:budget/pages/activityPage.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/pages/bankCertificatesPage.dart';
import 'package:budget/pages/billSplitter.dart';
import 'package:budget/pages/budgetsListPage.dart';
import 'package:budget/pages/cashuAddAssetPage.dart';
import 'package:budget/pages/creditDebtTransactionsPage.dart';
import 'package:budget/pages/editCategoriesPage.dart';
import 'package:budget/pages/editWalletsPage.dart';
import 'package:budget/pages/financialImportPage.dart';
import 'package:budget/pages/financialInsightsPage.dart';
import 'package:budget/pages/householdPage.dart';
import 'package:budget/pages/investmentsPage.dart';
import 'package:budget/pages/notificationsPage.dart';
import 'package:budget/pages/objectivesListPage.dart';
import 'package:budget/pages/planningScenariosPage.dart';
import 'package:budget/pages/settingsPage.dart';
import 'package:budget/pages/subscriptionsPage.dart';
import 'package:budget/pages/transactionsListPage.dart';
import 'package:budget/pages/transferHistoryPage.dart';
import 'package:budget/pages/upcomingOverdueTransactionsPage.dart';
import 'package:budget/pages/wealthAssetsPage.dart';
import 'package:budget/struct/financialAssistant.dart';
import 'package:flutter/material.dart';

({String en, String ar, Widget page}) assistantDestination(
        FinancialAssistantFeature feature) =>
    switch (feature) {
      FinancialAssistantFeature.accounts => (
          en: 'Accounts',
          ar: 'الحسابات',
          page: EditWalletsPage()
        ),
      FinancialAssistantFeature.addAccount => (
          en: 'Add an account',
          ar: 'إضافة حساب',
          page: const CashuAddAssetPage()
        ),
      FinancialAssistantFeature.cards => (
          en: 'Cards and accounts',
          ar: 'البطاقات والحسابات',
          page: EditWalletsPage()
        ),
      FinancialAssistantFeature.certificates => (
          en: 'Bank certificates',
          ar: 'الشهادات البنكية',
          page: const BankCertificatesPage()
        ),
      FinancialAssistantFeature.addCertificate => (
          en: 'Add a bank certificate',
          ar: 'إضافة شهادة بنكية',
          page: const BankCertificatesPage(openForm: true)
        ),
      FinancialAssistantFeature.bankMessages => (
          en: 'Bank Messages',
          ar: 'رسائل البنوك',
          page: const FinancialImportPage()
        ),
      FinancialAssistantFeature.transactions => (
          en: 'Transactions',
          ar: 'المعاملات',
          page: const TransactionsListPage()
        ),
      FinancialAssistantFeature.transfer => (
          en: 'Transfer between accounts',
          ar: 'تحويل بين الحسابات',
          page: const TransferBalancePage(allowEditWallet: true)
        ),
      FinancialAssistantFeature.transferHistory => (
          en: 'Transfer history',
          ar: 'سجل التحويلات',
          page: const TransferHistoryPage()
        ),
      FinancialAssistantFeature.budgets => (
          en: 'Budgets',
          ar: 'الميزانيات',
          page: const BudgetsListPage(enableBackButton: true)
        ),
      FinancialAssistantFeature.categories => (
          en: 'Categories',
          ar: 'التصنيفات',
          page: EditCategoriesPage()
        ),
      FinancialAssistantFeature.subscriptions => (
          en: 'Subscriptions',
          ar: 'الاشتراكات',
          page: const SubscriptionsPage()
        ),
      FinancialAssistantFeature.scheduled => (
          en: 'Scheduled payments',
          ar: 'الدفعات المجدولة',
          page: const UpcomingOverdueTransactions(overdueTransactions: null)
        ),
      FinancialAssistantFeature.goals => (
          en: 'Goals',
          ar: 'الأهداف',
          page: const ObjectivesListPage(backButton: true)
        ),
      FinancialAssistantFeature.loans => (
          en: 'Loans',
          ar: 'القروض',
          page: CreditDebtTransactions(isCredit: null)
        ),
      FinancialAssistantFeature.reports => (
          en: 'Reports',
          ar: 'التقارير',
          page: const FinancialInsightsPage()
        ),
      FinancialAssistantFeature.planning => (
          en: 'Cash flow planning',
          ar: 'تخطيط التدفقات النقدية',
          page: const PlanningScenariosPage()
        ),
      FinancialAssistantFeature.wealth => (
          en: 'Wealth',
          ar: 'الثروة',
          page: const WealthAssetsPage()
        ),
      FinancialAssistantFeature.investments => (
          en: 'Investments',
          ar: 'الاستثمارات',
          page: const InvestmentsPage()
        ),
      FinancialAssistantFeature.household => (
          en: 'Household',
          ar: 'الأسرة',
          page: const HouseholdPage()
        ),
      FinancialAssistantFeature.backup => (
          en: 'Google Drive backup',
          ar: 'النسخ على Google Drive',
          page: const AccountsPage()
        ),
      FinancialAssistantFeature.settings => (
          en: 'Settings',
          ar: 'الإعدادات',
          page: const SettingsPageFramework()
        ),
      FinancialAssistantFeature.appearance => (
          en: 'Appearance',
          ar: 'المظهر',
          page: const CashUAppearancePage()
        ),
      FinancialAssistantFeature.notifications => (
          en: 'Reminders',
          ar: 'التذكيرات',
          page: const NotificationsPage()
        ),
      FinancialAssistantFeature.activity => (
          en: 'Activity log',
          ar: 'سجل النشاط',
          page: const ActivityPage()
        ),
      FinancialAssistantFeature.billSplitter => (
          en: 'Bill splitter',
          ar: 'تقسيم الفواتير',
          page: const BillSplitter()
        ),
    };
