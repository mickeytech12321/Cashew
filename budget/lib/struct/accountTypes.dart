const accountTypeNames = {
  'unspecified': ('General', 'عام'),
  'cash': ('Cash', 'نقدي'),
  'bank': ('Bank account', 'حساب بنكي'),
  'debit': ('Debit card', 'بطاقة خصم'),
  'prepaid': ('Prepaid card', 'بطاقة مسبقة الدفع'),
  'ewallet': ('E-wallet', 'محفظة إلكترونية'),
  'credit': ('Credit card', 'بطاقة ائتمان'),
  'savings': ('Savings', 'مدخرات'),
  'investment': ('Investment', 'استثمار'),
};

String accountTypeLabel(String? type, {required bool arabic}) {
  final (en, ar) = accountTypeNames[type] ?? accountTypeNames['unspecified']!;
  return arabic ? ar : en;
}
