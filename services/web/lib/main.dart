import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api_transport.dart';

const apiBase = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:3000/api/v1',
);
const green = Color(0xFF247A53);
const ink = Color(0xFF17231C);
const muted = Color(0xFF78847D);
const canvas = Color(0xFFF6F8F6);
const incomeColor = Color(0xFF247A53);
const expenseColor = Color(0xFFDC765E);

void main() => runApp(const BudgifyApp());

class BudgifyApp extends StatelessWidget {
  const BudgifyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Budgify',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: green,
            surface: Colors.white,
            primary: green,
          ),
          scaffoldBackgroundColor: canvas,
          fontFamily: 'Arial',
          textTheme: const TextTheme(
            headlineMedium: TextStyle(color: ink, fontWeight: FontWeight.w700, letterSpacing: -1.2),
            titleLarge: TextStyle(color: ink, fontWeight: FontWeight.w700),
            titleMedium: TextStyle(color: ink, fontWeight: FontWeight.w600),
            bodyMedium: TextStyle(color: ink),
            bodySmall: TextStyle(color: muted),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFFF7F9F7),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE7ECE8))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: green, width: 1.4)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          ),
        ),
        home: const FinanceHome(),
      );
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Api {
  Api() : _client = createApiClient();
  late final http.Client _client;
  String? csrf;
  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$apiBase$path').replace(queryParameters: query);

  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) async {
    final response = await _client.get(_uri(path, query), headers: _headers());
    return _decode(response);
  }

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) async {
    final response = await _client.post(
      _uri(path),
      headers: _headers(mutate: true),
      body: jsonEncode(body ?? const {}),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> put(String path, Map<String, dynamic> body) async {
    final response = await _client.put(_uri(path), headers: _headers(mutate: true), body: jsonEncode(body));
    return _decode(response);
  }

  Future<void> delete(String path) async {
    final response = await _client.delete(_uri(path), headers: _headers(mutate: true));
    _decode(response);
  }

  Map<String, String> _headers({bool mutate = false}) => {
        'Content-Type': 'application/json',
        if (mutate && csrf != null) 'X-CSRF-Token': csrf!,
      };

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode == 204 || response.body.isEmpty) return {};
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      if (decoded['csrfToken'] is String) csrf = decoded['csrfToken'] as String;
      if (response.statusCode >= 200 && response.statusCode < 300) return decoded;
      final error = decoded['error'];
      throw ApiException(error is Map ? '${error['message'] ?? 'Request failed'}' : 'Request failed');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return {};
    throw ApiException('Request failed (${response.statusCode}).');
  }

  void close() => _client.close();
}

class FinanceHome extends StatefulWidget {
  const FinanceHome({super.key});
  @override
  State<FinanceHome> createState() => _FinanceHomeState();
}

class _FinanceHomeState extends State<FinanceHome> {
  final Api api = Api();
  Map<String, dynamic>? user;
  List<Map<String, dynamic>> transactions = [];
  List<Map<String, dynamic>> budgets = [];
  List<Map<String, dynamic>> categories = [];
  Map<String, dynamic> reports = {};
  bool loading = true;
  bool busy = false;
  String? error;
  int page = 1;
  int navIndex = 0;
  String search = '';
  String typeFilter = 'all';
  String sortFilter = 'date_desc';
  String? categoryFilter;
  bool hasMore = false;
  String reportPeriod = 'month';
  bool demoExists = false;
  final searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    searchController.dispose();
    api.close();
    super.dispose();
  }

  Future<void> _initialize() async {
    setState(() => loading = true);
    try {
      await api.get('/auth/csrf');
      final session = await api.get('/auth/me');
      user = session['user'] as Map<String, dynamic>?;
      if (user != null) await _loadData();
    } on ApiException catch (e) {
      if (!e.message.contains('sign in') && !e.message.contains('expired')) error = e.message;
    } catch (e) {
      error = 'Could not reach Budgify API at $apiBase. Start the API and refresh.';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _loadData() async {
    final query = <String, String>{
      'search': search,
      'sort': sortFilter,
      'page': '$page',
      'limit': '50',
      if (typeFilter != 'all') 'type': typeFilter,
      'categoryId': ?categoryFilter,
    };
    query.removeWhere((key, value) => value.isEmpty);
    final now = DateTime.now();
    final firstOfMonth = switch (reportPeriod) {
      'quarter' => now.subtract(const Duration(days: 89)),
      'year' => DateTime(now.year, 1, 1),
      _ => DateTime(now.year, now.month, 1),
    };
    final from = _date(firstOfMonth);
    final to = _date(now);
    final values = await Future.wait([
      api.get('/transactions', query),
      api.get('/budgets'),
      api.get('/categories'),
      api.get('/reports', {'from': from, 'to': to}),
    ]);
    transactions = _items(values[0]);
    hasMore = values[0]['hasMore'] == true;
    budgets = _items(values[1]);
    categories = _items(values[2]);
    reports = values[3];
    demoExists = transactions.any((item) => item['isDemo'] == true) ||
        budgets.any((item) => item['isDemo'] == true);
  }

  List<Map<String, dynamic>> _items(Map<String, dynamic> response) =>
      (response['items'] as List? ?? const []).whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();

  Future<void> _refresh({bool showSpinner = false}) async {
    page = 1;
    if (showSpinner) setState(() => busy = true);
    try {
      await _loadData();
      error = null;
    } catch (e) {
      error = e is ApiException ? e.message : 'Something went wrong while loading your data.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _loadMore() async {
    if (!hasMore || busy) return;
    setState(() => busy = true);
    final nextPage = page + 1;
    final query = <String, String>{
      'search': search,
      'sort': sortFilter,
      'page': '$nextPage',
      'limit': '50',
      if (typeFilter != 'all') 'type': typeFilter,
      'categoryId': ?categoryFilter,
    }..removeWhere((key, value) => value.isEmpty);
    try {
      final response = await api.get('/transactions', query);
      transactions.addAll(_items(response));
      page = nextPage;
      hasMore = response['hasMore'] == true;
      error = null;
    } catch (e) {
      error = e is ApiException ? e.message : 'Could not load more transactions.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _authenticate(bool register, String email, String password) async {
    setState(() { busy = true; error = null; });
    try {
      final response = await api.post(register ? '/auth/register' : '/auth/login', {'email': email, 'password': password});
      user = response['user'] as Map<String, dynamic>?;
      await _loadData();
      if (mounted) setState(() { loading = false; busy = false; });
    } catch (e) {
      if (mounted) setState(() { error = e is ApiException ? e.message : 'Unable to sign in right now.'; busy = false; });
      rethrow;
    }
  }

  Future<void> _logout() async {
    try {
      await api.post('/auth/logout');
    } catch (_) {
      // The session cookie may already have expired; clear the local view either way.
    }
    if (mounted) {
      setState(() {
        user = null;
        transactions = [];
        budgets = [];
        categories = [];
        reports = {};
        error = null;
      });
    }
  }

  Future<void> _showTransactionForm({Map<String, dynamic>? item}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => TransactionDialog(api: api, categories: categories, existing: item),
    );
    if (saved == true) await _refresh();
  }

  Future<void> _showBudgetForm({Map<String, dynamic>? item}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => BudgetDialog(api: api, categories: categories.where((c) => c['type'] == 'expense').toList(), existing: item),
    );
    if (saved == true) await _refresh();
  }

  Future<void> _deleteItem(String path, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this item?'),
        content: Text('$name will be permanently removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await api.delete(path);
      await _refresh();
    } catch (e) {
      _toast(e is ApiException ? e.message : 'Could not delete item.');
    }
  }

  Future<void> _demoAction(bool remove) async {
    try {
      if (remove) {
        await api.delete('/demo-data');
      } else {
        await api.post('/demo-data');
      }
      await _refresh();
      _toast(remove ? 'Demo records removed.' : 'Demo records added.');
    } catch (e) {
      _toast(e is ApiException ? e.message : 'Could not update demo data.');
    }
  }

  void _toast(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: green)));
    }
    if (user == null) {
      return AuthScreen(
        api: api,
        error: error,
        busy: busy,
        onAuthenticate: _authenticate,
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 940;
      final narrow = constraints.maxWidth < 640;
      final content = _mainContent(narrow);
      return Scaffold(
        drawer: wide ? null : Drawer(child: _navigation(dense: false, closeOnSelect: true)),
        appBar: !wide
            ? AppBar(
                title: const BrandMark(compact: true),
                actions: [
                  IconButton(tooltip: 'Add transaction', onPressed: () => _showTransactionForm(), icon: const Icon(Icons.add_circle_outline)),
                ],
              )
            : null,
        body: Row(
          children: [
            if (wide) SizedBox(width: 248, child: _navigation(dense: true)),
            Expanded(
              child: Column(
                children: [
                  if (wide) _topBar(),
                  if (busy) const LinearProgressIndicator(minHeight: 2),
                  Expanded(child: content),
                ],
              ),
            ),
          ],
        ),
        floatingActionButton: narrow && navIndex == 1
            ? FloatingActionButton.extended(
                onPressed: () => _showTransactionForm(),
                backgroundColor: green,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              )
            : null,
      );
    });
  }

  Widget _topBar() => Container(
        height: 78,
        padding: const EdgeInsets.symmetric(horizontal: 34),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: Color(0xFFEAEEEB)))),
        child: Row(
          children: [
            const Spacer(),
            IconButton(onPressed: () => _refresh(showSpinner: true), tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded, color: muted)),
            const SizedBox(width: 10),
            CircleAvatar(radius: 18, backgroundColor: const Color(0xFFE5F2E9), child: Text('${user?['email']}'.substring(0, 1).toUpperCase(), style: const TextStyle(color: green, fontWeight: FontWeight.bold))),
            const SizedBox(width: 10),
            ConstrainedBox(constraints: const BoxConstraints(maxWidth: 210), child: Text('${user?['email']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
            const SizedBox(width: 12),
            IconButton(onPressed: _logout, tooltip: 'Sign out', icon: const Icon(Icons.logout_rounded, color: muted)),
          ],
        ),
      );

  Widget _navigation({required bool dense, bool closeOnSelect = false}) {
    final entries = [
      (Icons.grid_view_rounded, 'Overview'),
      (Icons.receipt_long_rounded, 'Transactions'),
      (Icons.account_balance_wallet_outlined, 'Budgets'),
      (Icons.insights_rounded, 'Reports'),
    ];
    return Container(
      color: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(dense ? 25 : 22, 24, 18, 30),
              child: const BrandMark(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 0, 12),
              child: Text('WORKSPACE', style: TextStyle(color: muted.withValues(alpha: .8), fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            ),
            for (var i = 0; i < entries.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                child: Material(
                  color: navIndex == i ? const Color(0xFFEAF4ED) : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                  child: ListTile(
                    leading: Icon(entries[i].$1, color: navIndex == i ? green : muted, size: 21),
                    title: Text(entries[i].$2, style: TextStyle(color: navIndex == i ? green : const Color(0xFF58635C), fontWeight: navIndex == i ? FontWeight.w700 : FontWeight.w500, fontSize: 14)),
                    dense: true,
                    onTap: () {
                      setState(() => navIndex = i);
                      if (closeOnSelect) Navigator.pop(context);
                    },
                  ),
                ),
              ),
            const Spacer(),
            if (dense)
              Padding(
                padding: const EdgeInsets.fromLTRB(21, 0, 18, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Divider(color: Color(0xFFEDF0ED), height: 26),
                    Row(children: [
                      CircleAvatar(radius: 17, backgroundColor: const Color(0xFFE5F2E9), child: Text('${user?['email']}'.substring(0, 1).toUpperCase(), style: const TextStyle(color: green, fontSize: 12))),
                      const SizedBox(width: 10),
                      Expanded(child: Text('${user?['email']}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                      IconButton(tooltip: 'Sign out', onPressed: _logout, icon: const Icon(Icons.logout_rounded, color: muted, size: 19)),
                    ]),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _mainContent(bool narrow) {
    if (error != null && transactions.isEmpty && navIndex == 0) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off_outlined, size: 42, color: muted),
        const SizedBox(height: 14),
        Text(error!, textAlign: TextAlign.center),
        const SizedBox(height: 14),
        OutlinedButton.icon(onPressed: () => _refresh(showSpinner: true), icon: const Icon(Icons.refresh), label: const Text('Try again')),
      ])));
    }
    return switch (navIndex) {
      1 => _transactionsPage(narrow),
      2 => _budgetsPage(narrow),
      3 => _reportsPage(narrow),
      _ => _overviewPage(narrow),
    };
  }

  Widget _pageFrame({required String title, String? subtitle, required List<Widget> children, bool narrow = false, Widget? action}) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(narrow ? 18 : 34, narrow ? 18 : 31, narrow ? 18 : 34, 36),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1320),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: narrow ? 25 : 30, fontWeight: FontWeight.w700, letterSpacing: -0.8, color: ink)),
                if (subtitle != null) ...[const SizedBox(height: 5), Text(subtitle, style: const TextStyle(color: muted, fontSize: 13))],
              ])),
              ?action,
            ]),
            const SizedBox(height: 25),
            ...children,
          ]),
        ),
      ),
    );
  }

  Widget _overviewPage(bool narrow) {
    final totals = (reports['totals'] as List? ?? const []).whereType<Map>().toList();
    final income = _sum(totals, 'income');
    final expenses = _sum(totals, 'expense');
    final balance = income - expenses;
    final budgetRemaining = budgets.fold<double>(
      0,
      (remaining, budget) => remaining + _number(budget['amount']) - _number(budget['spent']),
    );
    final selectedRange = _reportRangeText();
    final width = MediaQuery.sizeOf(context).width;
    final cardCount = width < 720 ? 1 : (width < 1150 ? 2 : 4);
    final stats = [
      _Metric('Total income', income, Icons.south_west_rounded, incomeColor, selectedRange),
      _Metric('Total expenses', expenses, Icons.north_east_rounded, expenseColor, selectedRange),
      _Metric('Available balance', balance, Icons.account_balance_wallet_outlined, green, 'Income minus expenses'),
      _Metric('Remaining budget', budgetRemaining, Icons.pie_chart_outline_rounded, const Color(0xFF7389CF), 'Across ${budgets.length} budgets'),
    ];
    return _pageFrame(
      title: 'Good ${_greeting()}, ${('${user?['email']}'.split('@').first)}',
      subtitle: 'Here’s your money at a glance for $selectedRange.',
      narrow: narrow,
      action: FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: green, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14)),
        onPressed: () => _showTransactionForm(),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add transaction'),
      ),
      children: [
        if (demoExists) _demoBanner(),
        LayoutBuilder(builder: (context, constraints) {
          final columns = cardCount.clamp(1, (constraints.maxWidth / 225).floor().clamp(1, 4));
          return GridView.count(
            crossAxisCount: columns,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: columns == 1 ? 3.2 : 1.65,
            children: stats.map((stat) => _MetricCard(metric: stat)).toList(),
          );
        }),
        const SizedBox(height: 20),
        LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth < 760) {
            return Column(children: [
              _panel(child: _spendingChart(height: 232), title: 'Spending overview', trailing: const Text('Last 30 days', style: TextStyle(color: muted, fontSize: 11))),
              const SizedBox(height: 16),
              _budgetSummary(),
            ]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 6, child: _panel(child: _spendingChart(height: 254), title: 'Spending overview', trailing: const Text('Last 30 days', style: TextStyle(color: muted, fontSize: 11)))),
            const SizedBox(width: 16),
            Expanded(flex: 4, child: _budgetSummary()),
          ]);
        }),
        const SizedBox(height: 21),
        _panel(
          title: 'Recent transactions',
          trailing: TextButton(onPressed: () => setState(() => navIndex = 1), child: const Text('View all')),
          child: transactions.isEmpty
              ? _empty('No transactions yet', 'Add an income or expense to see your activity here.', Icons.receipt_long_outlined, action: _emptyActions())
              : Column(children: transactions.take(5).map((item) => _transactionRow(item, compact: true)).toList()),
        ),
        if (error != null) _inlineError(),
      ],
    );
  }

  Widget _transactionsPage(bool narrow) => _pageFrame(
        title: 'Transactions',
        subtitle: 'Keep every income and expense in one place.',
        narrow: narrow,
        action: narrow ? const SizedBox.shrink() : FilledButton.icon(
          onPressed: () => _showTransactionForm(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add transaction'),
          style: FilledButton.styleFrom(backgroundColor: green, foregroundColor: Colors.white),
        ),
        children: [
          _panel(
            child: Column(children: [
              Wrap(spacing: 12, runSpacing: 10, children: [
                SizedBox(
                  width: math.min(MediaQuery.sizeOf(context).width - (narrow ? 44 : 340), 390),
                  child: TextField(
                    controller: searchController,
                    decoration: const InputDecoration(hintText: 'Search transactions', prefixIcon: Icon(Icons.search_rounded)),
                    onChanged: (value) {
                      search = value;
                      _refresh();
                    },
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: DropdownButtonFormField<String>(
                    initialValue: typeFilter,
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.filter_list_rounded), contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 9)),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('All types')),
                      DropdownMenuItem(value: 'income', child: Text('Income')),
                      DropdownMenuItem(value: 'expense', child: Text('Expenses')),
                    ],
                    onChanged: (value) {
                      typeFilter = value ?? 'all';
                      _refresh();
                    },
                  ),
                ),
                SizedBox(
                  width: 190,
                  child: DropdownButtonFormField<String?>(
                    initialValue: categoryFilter,
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.category_outlined), contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 9)),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('All categories')),
                      ...categories.map((category) => DropdownMenuItem<String?>(value: category['id'] as String, child: Text(category['name'] as String, overflow: TextOverflow.ellipsis))),
                    ],
                    onChanged: (value) {
                      categoryFilter = value;
                      _refresh();
                    },
                  ),
                ),
                SizedBox(
                  width: 190,
                  child: DropdownButtonFormField<String>(
                    initialValue: sortFilter,
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.swap_vert_rounded), contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 9)),
                    items: const [
                      DropdownMenuItem(value: 'date_desc', child: Text('Newest first')),
                      DropdownMenuItem(value: 'date_asc', child: Text('Oldest first')),
                      DropdownMenuItem(value: 'amount_desc', child: Text('Largest amount')),
                      DropdownMenuItem(value: 'amount_asc', child: Text('Smallest amount')),
                    ],
                    onChanged: (value) {
                      sortFilter = value ?? 'date_desc';
                      _refresh();
                    },
                  ),
                ),
              ]),
              const SizedBox(height: 15),
              if (transactions.isEmpty)
                _empty(search.isEmpty ? 'No transactions yet' : 'No matches found',
                    search.isEmpty ? 'Create your first transaction or add optional demo data.' : 'Try a different search or filter.',
                    Icons.receipt_long_outlined,
                    action: search.isEmpty ? _emptyActions() : null)
              else ...[
                if (!narrow) _transactionHeader(),
                ...transactions.map((item) => _transactionRow(item, compact: narrow)),
                if (hasMore) Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Center(child: OutlinedButton.icon(
                    onPressed: busy ? null : _loadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Load more'),
                  )),
                ),
              ],
            ]),
          ),
          if (error != null) _inlineError(),
        ],
      );

  Widget _budgetsPage(bool narrow) => _pageFrame(
        title: 'Budgets',
        subtitle: 'Make a plan for what matters.',
        narrow: narrow,
        action: FilledButton.icon(
          onPressed: () => _showBudgetForm(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New budget'),
          style: FilledButton.styleFrom(backgroundColor: green, foregroundColor: Colors.white),
        ),
        children: [
          if (budgets.isEmpty)
            _panel(child: _empty('A little plan goes a long way', 'Set a budget to keep spending in view. You can also explore with optional demo data.', Icons.account_balance_wallet_outlined, action: _emptyActions()))
          else
            LayoutBuilder(builder: (context, constraints) {
              final cols = constraints.maxWidth < 650 ? 1 : constraints.maxWidth < 1000 ? 2 : 3;
              return GridView.count(
                crossAxisCount: cols,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 15,
                mainAxisSpacing: 15,
                childAspectRatio: cols == 1 ? 2.2 : 1.45,
                children: budgets.map((item) => _budgetCard(item)).toList(),
              );
            }),
          if (error != null) _inlineError(),
        ],
      );

  Widget _reportsPage(bool narrow) {
    final totals = (reports['totals'] as List? ?? const []).whereType<Map>().toList();
    final income = _sum(totals, 'income');
    final expenses = _sum(totals, 'expense');
    final categoryRows = (reports['byCategory'] as List? ?? const []).whereType<Map>().toList();
    return _pageFrame(
      title: 'Reports',
      subtitle: 'A clearer picture of how your money moves.',
      narrow: narrow,
      action: DropdownButton<String>(
        value: reportPeriod,
        borderRadius: BorderRadius.circular(12),
        items: const [
          DropdownMenuItem(value: 'month', child: Text('This month')),
          DropdownMenuItem(value: 'quarter', child: Text('Last 90 days')),
          DropdownMenuItem(value: 'year', child: Text('This year')),
        ],
        onChanged: (value) {
          reportPeriod = value ?? 'month';
          _refresh(showSpinner: true);
        },
      ),
      children: [
        Row(children: [
          Expanded(child: _MetricCard(metric: _Metric('Income', income, Icons.south_west_rounded, incomeColor, 'This month'))),
          const SizedBox(width: 12),
          Expanded(child: _MetricCard(metric: _Metric('Expenses', expenses, Icons.north_east_rounded, expenseColor, 'This month'))),
        ]),
        const SizedBox(height: 16),
        _panel(child: _spendingChart(height: 310), title: 'Income & expenses', trailing: Text(_reportRangeText(), style: const TextStyle(color: muted, fontSize: 11))),
        const SizedBox(height: 16),
        _panel(
          title: 'Spending by category',
          child: categoryRows.isEmpty
              ? _empty('Nothing to report yet', 'Your expense categories will appear here after you add transactions.', Icons.donut_small_outlined)
              : Column(children: categoryRows.map((row) {
                  final amount = _number(row['total']);
                  final max = categoryRows.map((e) => _number(e['total'])).fold<double>(1, math.max);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    child: Row(children: [
                      Expanded(flex: 2, child: Text('${row['name']}', style: const TextStyle(fontWeight: FontWeight.w600))),
                      Expanded(flex: 4, child: ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: (amount / max).clamp(0, 1), minHeight: 9, backgroundColor: const Color(0xFFEDF2EE), color: green))),
                      const SizedBox(width: 14),
                      Text(_money(amount), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                  );
                }).toList()),
        ),
        if (error != null) _inlineError(),
      ],
    );
  }

  Widget _transactionHeader() => const Padding(
        padding: EdgeInsets.fromLTRB(12, 3, 10, 10),
        child: Row(children: [
          Expanded(flex: 5, child: Text('DESCRIPTION', style: _headerStyle)),
          Expanded(flex: 2, child: Text('CATEGORY', style: _headerStyle)),
          Expanded(flex: 2, child: Text('DATE', style: _headerStyle)),
          Expanded(flex: 2, child: Text('AMOUNT', textAlign: TextAlign.right, style: _headerStyle)),
          SizedBox(width: 70),
        ]),
      );

  Widget _transactionRow(Map<String, dynamic> item, {required bool compact}) {
    final isIncome = item['type'] == 'income';
    final amount = _number(item['amount']);
    final title = (item['description'] as String?)?.trim().isNotEmpty == true ? item['description'] as String : (item['categoryName'] ?? 'Transaction').toString();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF0F2F0)))),
      child: compact
          ? Row(children: [
              _transactionIcon(item['categoryName']?.toString() ?? title, isIncome),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 4),
                Text('${item['categoryName'] ?? (isIncome ? 'Income' : 'Expense')} · ${_prettyDate(item['date'])}', style: const TextStyle(color: muted, fontSize: 11)),
              ])),
              Text('${isIncome ? '+' : '−'}${_money(amount)}', style: TextStyle(fontWeight: FontWeight.w700, color: isIncome ? incomeColor : ink, fontSize: 13)),
              PopupMenuButton<String>(tooltip: 'Transaction actions', onSelected: (choice) {
                if (choice == 'edit') _showTransactionForm(item: item);
                if (choice == 'delete') _deleteItem('/transactions/${item['id']}', title);
              }, itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ]),
            ])
          : Row(children: [
              Expanded(flex: 5, child: Row(children: [
                _transactionIcon(item['categoryName']?.toString() ?? title, isIncome),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  if (item['isDemo'] == true) const Text('Demo data', style: TextStyle(color: muted, fontSize: 10)),
                ])),
              ])),
              Expanded(flex: 2, child: Text('${item['categoryName'] ?? '—'}', style: const TextStyle(color: muted, fontSize: 12))),
              Expanded(flex: 2, child: Text(_prettyDate(item['date']), style: const TextStyle(color: muted, fontSize: 12))),
              Expanded(flex: 2, child: Text('${isIncome ? '+' : '−'}${_money(amount)}', textAlign: TextAlign.right, style: TextStyle(color: isIncome ? incomeColor : ink, fontWeight: FontWeight.w700))),
              SizedBox(width: 70, child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                IconButton(tooltip: 'Edit', onPressed: () => _showTransactionForm(item: item), icon: const Icon(Icons.edit_outlined, size: 17, color: muted)),
                IconButton(tooltip: 'Delete', onPressed: () => _deleteItem('/transactions/${item['id']}', title), icon: const Icon(Icons.delete_outline, size: 17, color: muted)),
              ])),
            ]),
    );
  }

  Widget _transactionIcon(String name, bool isIncome) {
    final icon = name.toLowerCase().contains('food') ? Icons.restaurant_outlined
        : name.toLowerCase().contains('transport') ? Icons.directions_transit_outlined
        : name.toLowerCase().contains('hous') ? Icons.home_outlined
        : isIncome ? Icons.south_west_rounded : Icons.shopping_bag_outlined;
    return Container(width: 38, height: 38, decoration: BoxDecoration(color: isIncome ? const Color(0xFFEAF4ED) : const Color(0xFFFFF0EC), borderRadius: BorderRadius.circular(12)), child: Icon(icon, size: 18, color: isIncome ? green : expenseColor));
  }

  Widget _budgetCard(Map<String, dynamic> budget) {
    final spent = _number(budget['spent']);
    final amount = _number(budget['amount']);
    final progress = (spent / math.max(amount, 1)).clamp(0.0, 1.0);
    final over = spent > amount;
    return _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: const Color(0xFFEAF4ED), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.savings_outlined, color: green)),
          const Spacer(),
          PopupMenuButton<String>(onSelected: (value) {
            if (value == 'edit') _showBudgetForm(item: budget);
            if (value == 'delete') _deleteItem('/budgets/${budget['id']}', 'Budget');
          }, itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ]),
        ]),
        const SizedBox(height: 13),
        Text('${budget['categoryName'] ?? 'Overall spending'}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 3),
        Text('${_capitalize('${budget['period']}')} budget', style: const TextStyle(color: muted, fontSize: 12)),
        const Spacer(),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_money(spent), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(width: 4),
          Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('of ${_money(amount)}', style: const TextStyle(color: muted, fontSize: 11))),
          const Spacer(),
          Text('${(progress * 100).round()}%', style: TextStyle(color: over ? expenseColor : green, fontWeight: FontWeight.w700, fontSize: 12)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(borderRadius: BorderRadius.circular(10), child: LinearProgressIndicator(value: progress, minHeight: 8, color: over ? expenseColor : green, backgroundColor: const Color(0xFFEDF2EE))),
        const SizedBox(height: 8),
        Text(over ? '${_money(spent - amount)} over budget' : '${_money(amount - spent)} remaining', style: TextStyle(color: over ? expenseColor : muted, fontSize: 11)),
      ]),
    );
  }

  Widget _budgetSummary() => _panel(
        title: 'Budget progress',
        trailing: TextButton(onPressed: () => setState(() => navIndex = 2), child: const Text('Manage')),
        child: budgets.isEmpty
            ? _empty('No budgets yet', 'Set a monthly target to keep a little extra in view.', Icons.savings_outlined, action: OutlinedButton(onPressed: () => _showBudgetForm(), child: const Text('Create a budget')))
            : Column(children: budgets.take(3).map((b) {
                final spent = _number(b['spent']);
                final total = _number(b['amount']);
                final progress = (spent / math.max(total, 1)).clamp(0.0, 1.0);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(children: [
                    Row(children: [
                      Expanded(child: Text('${b['categoryName'] ?? 'Overall spending'}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                      Text('${_money(spent)} / ${_money(total)}', style: const TextStyle(color: muted, fontSize: 11)),
                    ]),
                    const SizedBox(height: 9),
                    ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: progress, minHeight: 7, color: progress >= 1 ? expenseColor : green, backgroundColor: const Color(0xFFEDF2EE))),
                  ]),
                );
              }).toList()),
      );

  Widget _spendingChart({required double height}) {
    final timeline = (reports['timeline'] as List? ?? const []).whereType<Map>().toList();
    if (timeline.isEmpty) {
      return SizedBox(height: height, child: _empty('Your story starts here', 'Add a few transactions and your income and spending trends will show up.', Icons.show_chart_rounded));
    }
    final values = timeline.map((item) => (_number(item['income']), _number(item['expenses']))).toList();
    final maxValue = values.expand((p) => [p.$1, p.$2]).fold<double>(1, math.max);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _legend(incomeColor, 'Income'),
        const SizedBox(width: 18),
        _legend(expenseColor, 'Expenses'),
      ]),
      const SizedBox(height: 19),
      SizedBox(
        height: height - 79,
        width: double.infinity,
        child: CustomPaint(painter: _ChartPainter(values: values, max: maxValue)),
      ),
      const SizedBox(height: 12),
      Row(children: List.generate(values.length, (index) => Expanded(child: Text('W${index + 1}', textAlign: TextAlign.center, style: const TextStyle(color: muted, fontSize: 10))))),
    ]);
  }

  Widget _legend(Color color, String label) => Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5))),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: muted, fontSize: 11)),
      ]);

  Widget _panel({required Widget child, String? title, Widget? trailing}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFFEBEFEB)), borderRadius: BorderRadius.circular(16), boxShadow: const [BoxShadow(color: Color(0x080D2515), blurRadius: 16, offset: Offset(0, 4))]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (title != null) ...[
            Row(children: [Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))), ?trailing]),
            const SizedBox(height: 12),
          ],
          child,
        ]),
      );

  Widget _empty(String title, String description, IconData icon, {Widget? action}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 10),
        child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 54, height: 54, decoration: BoxDecoration(color: const Color(0xFFF0F5F1), borderRadius: BorderRadius.circular(17)), child: Icon(icon, color: green)),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 340), child: Text(description, textAlign: TextAlign.center, style: const TextStyle(color: muted, fontSize: 12, height: 1.5))),
          if (action != null) ...[const SizedBox(height: 14), action],
        ])),
      );

  Widget _emptyActions() => Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
        FilledButton.icon(
          onPressed: () => navIndex == 2 ? _showBudgetForm() : _showTransactionForm(),
          icon: const Icon(Icons.add, size: 16),
          label: Text(navIndex == 2 ? 'Create budget' : 'Add transaction'),
          style: FilledButton.styleFrom(backgroundColor: green, foregroundColor: Colors.white),
        ),
        OutlinedButton.icon(onPressed: () => _demoAction(false), icon: const Icon(Icons.auto_awesome_outlined, size: 16), label: const Text('Try demo data')),
      ]);

  Widget _inlineError() => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Material(color: const Color(0xFFFFF2EF), borderRadius: BorderRadius.circular(10), child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
          const Icon(Icons.info_outline, color: expenseColor, size: 18),
          const SizedBox(width: 9),
          Expanded(child: Text(error!, style: const TextStyle(color: Color(0xFF8D4839), fontSize: 12))),
          TextButton(onPressed: () => _refresh(showSpinner: true), child: const Text('Retry')),
        ]))),
      );

  Widget _demoBanner() => Container(
        margin: const EdgeInsets.only(bottom: 15),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        decoration: BoxDecoration(color: const Color(0xFFEAF4ED), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          const Icon(Icons.auto_awesome_outlined, color: green, size: 18),
          const SizedBox(width: 10),
          const Expanded(child: Text('You’re viewing optional demo records. Remove them any time.', style: TextStyle(color: Color(0xFF315C41), fontSize: 12))),
          TextButton(onPressed: () => _demoAction(true), child: const Text('Remove demo data')),
        ]),
      );

  double _sum(List<Map> rows, String type) =>
      rows.where((row) => row['type'] == type).fold<double>(0, (sum, row) => sum + _number(row['total']));

  String _reportRangeText() => switch (reportPeriod) {
        'quarter' => 'Last 90 days',
        'year' => 'This year',
        _ => DateTime.now().toLocaleMonth(),
      };
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.api, required this.error, required this.busy, required this.onAuthenticate});
  final Api api;
  final String? error;
  final bool busy;
  final Future<void> Function(bool register, String email, String password) onAuthenticate;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final formKey = GlobalKey<FormState>();
  final email = TextEditingController();
  final password = TextEditingController();
  bool register = false;
  bool obscure = true;
  String? localError;
  @override
  void dispose() { email.dispose(); password.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxWidth < 1020;
          return Row(children: [
            if (!compact)
              Expanded(
                child: Container(
                  height: double.infinity,
                  padding: const EdgeInsets.all(58),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1E6847), Color(0xFF123D2B)]),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const BrandMark(inverse: true),
                    const Spacer(),
                    const Text('Make room for\nthe good stuff.', style: TextStyle(color: Colors.white, fontSize: 52, height: 1.08, fontWeight: FontWeight.w700, letterSpacing: -2)),
                    const SizedBox(height: 20),
                    const Text('A calmer, clearer way to understand your money.', style: TextStyle(color: Color(0xFFD4E5DA), fontSize: 16)),
                    const SizedBox(height: 45),
                    Row(children: [
                      _feature(Icons.insights_outlined, 'Know where it goes'),
                      const SizedBox(width: 24),
                      _feature(Icons.savings_outlined, 'Plan what comes next'),
                    ]),
                    const Spacer(),
                    const Text('YOUR MONEY, IN BALANCE', style: TextStyle(color: Color(0xFFA8C9B5), fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 390),
                    child: Form(
                      key: formKey,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (compact) const Padding(padding: EdgeInsets.only(bottom: 43), child: BrandMark()),
                        Text(register ? 'Create your account' : 'Welcome back', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 26, letterSpacing: -.7)),
                        const SizedBox(height: 8),
                        Text(register ? 'A fresh start for your finances.' : 'Sign in to pick up where you left off.', style: const TextStyle(color: muted)),
                        const SizedBox(height: 30),
                        const Text('Email address', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 7),
                        TextFormField(
                          controller: email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(hintText: 'you@example.com', prefixIcon: Icon(Icons.mail_outline, size: 19)),
                          validator: (value) => value == null || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim()) ? 'Enter a valid email address.' : null,
                        ),
                        const SizedBox(height: 18),
                        const Text('Password', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 7),
                        TextFormField(
                          controller: password,
                          obscureText: obscure,
                          autofillHints: register ? const [AutofillHints.newPassword] : const [AutofillHints.password],
                          decoration: InputDecoration(
                            hintText: register ? 'At least 10 characters' : 'Enter your password',
                            prefixIcon: const Icon(Icons.lock_outline, size: 19),
                            suffixIcon: IconButton(onPressed: () => setState(() => obscure = !obscure), icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 19)),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) return 'Enter your password.';
                            if (register && value.length < 10) return 'Use at least 10 characters.';
                            if (value.length > 128) return 'Password must be 128 characters or less.';
                            return null;
                          },
                          onFieldSubmitted: (_) => _submit(),
                        ),
                        if ((localError ?? widget.error) != null)                         Padding(padding: const EdgeInsets.only(top: 12), child: Text(localError ?? widget.error!, style: const TextStyle(color: Color(0xFFBA5142), fontSize: 12))),
                        const SizedBox(height: 22),
                        SizedBox(
                          width: double.infinity,
                          height: 49,
                          child: FilledButton(
                            onPressed: widget.busy ? null : _submit,
                            style: FilledButton.styleFrom(backgroundColor: green, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                            child: widget.busy ? const SizedBox(width: 19, height: 19, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(register ? 'Create account' : 'Sign in', style: const TextStyle(fontWeight: FontWeight.w700)),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Center(child: TextButton(
                          onPressed: () => setState(() { register = !register; localError = null; }),
                          child: Text(register ? 'Already have an account? Sign in' : 'New to Budgify? Create an account', style: const TextStyle(color: green, fontWeight: FontWeight.w600)),
                        )),
                        const SizedBox(height: 22),
                        const Center(child: Text('Your finance data is private and only visible to you.', style: TextStyle(color: muted, fontSize: 11))),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ]);
        }),
      );

  Future<void> _submit() async {
    if (!formKey.currentState!.validate()) return;
    setState(() => localError = null);
    try {
      await widget.onAuthenticate(register, email.text.trim(), password.text);
    } catch (e) {
      if (mounted) setState(() => localError = e is ApiException ? e.message : 'Unable to continue.');
    }
  }

  Widget _feature(IconData icon, String label) => Row(children: [
        Icon(icon, color: const Color(0xFFB6D7C2), size: 20),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ]);
}

class TransactionDialog extends StatefulWidget {
  const TransactionDialog({super.key, required this.api, required this.categories, this.existing});
  final Api api;
  final List<Map<String, dynamic>> categories;
  final Map<String, dynamic>? existing;
  @override
  State<TransactionDialog> createState() => _TransactionDialogState();
}

class _TransactionDialogState extends State<TransactionDialog> {
  final form = GlobalKey<FormState>();
  late final TextEditingController amount;
  late final TextEditingController description;
  late String type;
  String? categoryId;
  late DateTime date;
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    type = existing?['type'] as String? ?? 'expense';
    amount = TextEditingController(text: existing?['amount']?.toString() ?? '');
    description = TextEditingController(text: existing?['description']?.toString() ?? '');
    categoryId = existing?['categoryId'] as String?;
    date = DateTime.tryParse(existing?['date']?.toString() ?? '') ?? DateTime.now();
  }
  @override
  void dispose() { amount.dispose(); description.dispose(); super.dispose(); }
  List<Map<String, dynamic>> get options => widget.categories.where((item) => item['type'] == type).toList();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? 'Add transaction' : 'Edit transaction'),
        content: SizedBox(
          width: 440,
          child: Form(
            key: form,
            child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'expense', label: Text('Expense'), icon: Icon(Icons.north_east)),
                  ButtonSegment(value: 'income', label: Text('Income'), icon: Icon(Icons.south_west)),
                ],
                selected: {type},
                onSelectionChanged: (value) => setState(() { type = value.first; categoryId = null; }),
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount', prefixText: '\$ ', hintText: '0.00'),
                validator: (value) {
                  final parsed = double.tryParse(value ?? '');
                  return parsed == null || !parsed.isFinite || parsed <= 0 ? 'Enter an amount greater than zero.' : null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: categoryId,
                decoration: const InputDecoration(labelText: 'Category'),
                items: options.map((item) => DropdownMenuItem(value: item['id'] as String, child: Text(item['name'] as String))).toList(),
                onChanged: (value) => setState(() => categoryId = value),
                validator: (value) => value == null ? 'Choose a category.' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: description,
                maxLength: 240,
                decoration: const InputDecoration(labelText: 'Description', hintText: 'What was this for?'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 366)));
                  if (picked != null) setState(() => date = picked);
                },
                icon: const Icon(Icons.calendar_today_outlined, size: 17),
                label: Text(_prettyDate(_date(date))),
              ),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: const TextStyle(color: expenseColor, fontSize: 12))),
            ])),
          ),
        ),
        actions: [
          TextButton(onPressed: saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: saving ? null : _save, child: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save')),
        ],
      );

  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    setState(() { saving = true; error = null; });
    final payload = {
      'categoryId': categoryId,
      'type': type,
      'amount': amount.text.trim(),
      'date': _date(date),
      'description': description.text.trim(),
    };
    try {
      final existing = widget.existing;
      if (existing == null) {
        await widget.api.post('/transactions', payload);
      } else {
        await widget.api.put('/transactions/${existing['id']}', payload);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { saving = false; error = e is ApiException ? e.message : 'Could not save transaction.'; });
    }
  }
}

class BudgetDialog extends StatefulWidget {
  const BudgetDialog({super.key, required this.api, required this.categories, this.existing});
  final Api api;
  final List<Map<String, dynamic>> categories;
  final Map<String, dynamic>? existing;
  @override
  State<BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<BudgetDialog> {
  final form = GlobalKey<FormState>();
  late final TextEditingController amount;
  late String period;
  String? categoryId;
  late DateTime startsOn;
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    amount = TextEditingController(text: widget.existing?['amount']?.toString() ?? '');
    period = widget.existing?['period'] as String? ?? 'monthly';
    categoryId = widget.existing?['categoryId'] as String?;
    startsOn = DateTime.tryParse(widget.existing?['startsOn']?.toString() ?? '') ?? DateTime.now();
  }
  @override
  void dispose() { amount.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? 'Create budget' : 'Edit budget'),
        content: SizedBox(width: 420, child: Form(key: form, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Budget amount', prefixText: '\$ '), validator: (v) => double.tryParse(v ?? '') == null || double.parse(v!) <= 0 ? 'Enter an amount greater than zero.' : null),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: categoryId,
            decoration: const InputDecoration(labelText: 'Category (optional)'),
            items: [const DropdownMenuItem<String>(value: null, child: Text('All expenses')), ...widget.categories.map((c) => DropdownMenuItem<String>(value: c['id'] as String, child: Text(c['name'] as String)))],
            onChanged: (value) => setState(() => categoryId = value),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: period,
            decoration: const InputDecoration(labelText: 'Budget period'),
            items: const [
              DropdownMenuItem(value: 'daily', child: Text('Daily')),
              DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
              DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
            ],
            onChanged: (value) => setState(() => period = value ?? 'monthly'),
          ),
          const SizedBox(height: 12),
          Row(children: [const Expanded(child: Text('Starts on')), TextButton(onPressed: () async {
            final picked = await showDatePicker(context: context, initialDate: startsOn, firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 366)));
            if (picked != null) setState(() => startsOn = picked);
          }, child: Text(_prettyDate(_date(startsOn))))]),
          if (error != null) Text(error!, style: const TextStyle(color: expenseColor, fontSize: 12)),
        ]))),
        actions: [
          TextButton(onPressed: saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: saving ? null : _save, child: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save budget')),
        ],
      );

  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    setState(() { saving = true; error = null; });
    try {
      final payload = {'categoryId': categoryId, 'period': period, 'amount': amount.text.trim(), 'startsOn': _date(startsOn)};
      final existing = widget.existing;
      if (existing == null) {
        await widget.api.post('/budgets', payload);
      } else {
        await widget.api.put('/budgets/${existing['id']}', payload);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { saving = false; error = e is ApiException ? e.message : 'Could not save budget.'; });
    }
  }
}

class _Metric {
  const _Metric(this.label, this.value, this.icon, this.color, this.note);
  final String label;
  final double value;
  final IconData icon;
  final Color color;
  final String note;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric});
  final _Metric metric;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFEBEFEB))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [
            Container(width: 34, height: 34, decoration: BoxDecoration(color: metric.color.withValues(alpha: .1), borderRadius: BorderRadius.circular(10)), child: Icon(metric.icon, color: metric.color, size: 18)),
            const Spacer(),
            Text(metric.note, style: const TextStyle(color: muted, fontSize: 10)),
          ]),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(metric.label, style: const TextStyle(color: muted, fontSize: 11)),
            const SizedBox(height: 4),
            Text(_money(metric.value), style: const TextStyle(color: ink, fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -.5)),
          ]),
        ]),
      );
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({required this.values, required this.max});
  final List<(double, double)> values;
  final double max;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = const Color(0xFFEDF1ED)..strokeWidth = 1;
    for (var row = 0; row < 4; row++) {
      final y = row * size.height / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.isEmpty) return;
    final slot = size.width / values.length;
    final barWidth = math.min(13.0, slot * .24);
    final scale = (size.height - 5) / max;
    final paints = [
      Paint()..color = incomeColor..style = PaintingStyle.fill,
      Paint()..color = expenseColor..style = PaintingStyle.fill,
    ];
    for (var i = 0; i < values.length; i++) {
      final center = slot * (i + .5);
      final incomeHeight = values[i].$1 * scale;
      final expenseHeight = values[i].$2 * scale;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(center - barWidth - 2, size.height - incomeHeight, barWidth, incomeHeight), const Radius.circular(5)), paints[0]);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(center + 2, size.height - expenseHeight, barWidth, expenseHeight), const Radius.circular(5)), paints[1]);
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) => oldDelegate.values != values || oldDelegate.max != max;
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.inverse = false, this.compact = false});
  final bool inverse;
  final bool compact;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: compact ? 31 : 35,
          height: compact ? 31 : 35,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(11)),
          child: Image.asset('assets/budgify-icon.png', fit: BoxFit.cover),
        ),
        const SizedBox(width: 10),
        Text('budgify', style: TextStyle(color: inverse ? Colors.white : ink, fontWeight: FontWeight.w800, fontSize: compact ? 20 : 22, letterSpacing: -.8)),
      ]);
}

const _headerStyle = TextStyle(color: muted, fontWeight: FontWeight.w700, fontSize: 9, letterSpacing: .7);

double _number(dynamic value) => double.tryParse(value?.toString() ?? '') ?? 0;
String _money(double value) => '\$${value.toStringAsFixed(2).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (match) => ',')}';
String _date(DateTime date) => '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
String _prettyDate(dynamic value) {
  final date = DateTime.tryParse(value?.toString() ?? '');
  if (date == null) return '—';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}
String _capitalize(String value) => value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';
String _greeting() {
  final hour = DateTime.now().hour;
  return hour < 12 ? 'morning' : hour < 17 ? 'afternoon' : 'evening';
}

extension on DateTime {
  String toLocaleMonth() {
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return '${months[month - 1]} $year';
  }
}
