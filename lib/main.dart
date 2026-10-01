import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

String proxmoxIp = "";
String proxmoxPort = "8006";
String pveUser = "root@pam";
String pveTokenId = "";
String pveSecret = "";

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final prefs = await SharedPreferences.getInstance();
  proxmoxIp = prefs.getString('proxmoxIp') ?? "";
  proxmoxPort = prefs.getString('proxmoxPort') ?? "8006";
  pveUser = prefs.getString('pveUser') ?? "root@pam";
  pveTokenId = prefs.getString('pveTokenId') ?? "";
  pveSecret = prefs.getString('pveSecret') ?? "";

  HttpOverrides.global = MyHttpOverrides();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mymomox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.white,
        cardColor: const Color(0xFF0A0A0A),
        fontFamily: 'Roboto',
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _currentIndex = 0;
  
  bool isLoading = true;
  String errorMessage = '';
  
  List<dynamic> nodes = [];
  List<dynamic> vms = [];
  List<dynamic> storages = []; 
  List<dynamic> logs = []; 

  Timer? _timer;

  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _tokenIdController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();

  @override
  void initState() {
    super.initState();
    
    if (proxmoxIp.isEmpty || pveTokenId.isEmpty || pveSecret.isEmpty) {
      _currentIndex = 3;
      isLoading = false;
      _populateSettings();
    } else {
      fetchData(isInitialLoad: true);
      _startTimer();
    }
  }

  void _populateSettings() {
    _ipController.text = proxmoxIp;
    _portController.text = proxmoxPort;
    _userController.text = pveUser;
    _tokenIdController.text = pveTokenId;
    _secretController.text = pveSecret;
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_currentIndex != 3) fetchData(isInitialLoad: false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ipController.dispose();
    _portController.dispose();
    _userController.dispose();
    _tokenIdController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    if (_ipController.text.trim().isEmpty || _secretController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IP Address dan Secret Key wajib diisi!'), backgroundColor: Colors.redAccent),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('proxmoxIp', _ipController.text.trim());
    await prefs.setString('proxmoxPort', _portController.text.trim().isEmpty ? "8006" : _portController.text.trim());
    await prefs.setString('pveUser', _userController.text.trim().isEmpty ? "root@pam" : _userController.text.trim());
    await prefs.setString('pveTokenId', _tokenIdController.text.trim());
    await prefs.setString('pveSecret', _secretController.text.trim());
    
    setState(() {
      proxmoxIp = prefs.getString('proxmoxIp')!;
      proxmoxPort = prefs.getString('proxmoxPort')!;
      pveUser = prefs.getString('pveUser')!;
      pveTokenId = prefs.getString('pveTokenId')!;
      pveSecret = prefs.getString('pveSecret')!;
      _currentIndex = 0; 
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved successfully!'), backgroundColor: Colors.teal),
    );
    
    fetchData(isInitialLoad: true);
    _startTimer();
  }

  Future<void> fetchData({bool isInitialLoad = false}) async {
    if (proxmoxIp.isEmpty || pveSecret.isEmpty) return;

    if (isInitialLoad) {
      setState(() {
        isLoading = true;
        errorMessage = '';
      });
    }

    try {
      final String fullApiToken = 'PVEAPIToken=$pveUser!$pveTokenId=$pveSecret';
      
      final headers = {
        'Authorization': fullApiToken,
        'Accept': 'application/json',
      };

      if (_currentIndex == 2) {
        final response = await http.get(Uri.parse('https://$proxmoxIp:$proxmoxPort/api2/json/cluster/log'), headers: headers).timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          final data = json.decode(response.body)['data'] as List;
          if (mounted) setState(() { logs = data.take(50).toList(); isLoading = false; errorMessage = ''; });
        } else {
          throw Exception('HTTP Error: ${response.statusCode}');
        }
        return; 
      }

      final response = await http.get(Uri.parse('https://$proxmoxIp:$proxmoxPort/api2/json/cluster/resources'), headers: headers).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body)['data'] as List;
        
        List<dynamic> rawNodes = data.where((item) => item['type'] == 'node').toList();
        List<dynamic> rawVms = data.where((item) => item['type'] == 'qemu' || item['type'] == 'lxc').toList();
        List<dynamic> rawStorages = data.where((item) => item['type'] == 'storage').toList();

        rawStorages.sort((a, b) {
          int cmp = a['storage'].toString().compareTo(b['storage'].toString());
          if (cmp != 0) return cmp;
          return a['node'].toString().compareTo(b['node'].toString());
        });
        
        rawVms.sort((a, b) => (a['vmid'] as int).compareTo(b['vmid'] as int));

        if (_currentIndex == 0) {
          List<Future<void>> nodeFutures = [];
          for (var node in rawNodes) {
            nodeFutures.add(
              http.get(Uri.parse('https://$proxmoxIp:$proxmoxPort/api2/json/nodes/${node['node']}/status'), headers: headers).then((res) {
                if (res.statusCode == 200) node['io_delay'] = json.decode(res.body)['data']['wait'] ?? 0.0;
              }).catchError((e) => node['io_delay'] = 0.0)
            );
          }
          await Future.wait(nodeFutures);
        }

        if (mounted) {
          setState(() { nodes = rawNodes; vms = rawVms; storages = rawStorages; isLoading = false; errorMessage = ''; });
        }
      } else {
        throw Exception('HTTP Error: ${response.statusCode} - Pastikan Token Valid');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (isInitialLoad || (nodes.isEmpty && logs.isEmpty)) { errorMessage = e.toString(); isLoading = false; }
        });
      }
    }
  }

  String formatBytes(dynamic bytes) {
    if (bytes == null || bytes == 0) return '0 GB';
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }

  String formatUptime(dynamic seconds) {
    if (seconds == null || seconds == 0) return 'Offline';
    int sec = seconds is int ? seconds : (seconds as double).toInt();
    int d = sec ~/ 86400;
    int h = (sec % 86400) ~/ 3600;
    return '${d}d ${h}h';
  }

  String formatTimestamp(dynamic unixTime) {
    if (unixTime == null) return '-';
    int timestamp = unixTime is int ? unixTime : (unixTime as double).toInt();
    DateTime date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  // ==== SIDEBAR DRAWER ====
  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF0A0A0A),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(top: 60, bottom: 30, left: 24, right: 24),
            decoration: const BoxDecoration(color: Colors.black, border: Border(bottom: BorderSide(color: Colors.white10))),
            child: Row(
              children: [
                const Icon(Icons.dns, color: Colors.white, size: 38),
                const SizedBox(width: 16),
                const Text('mymomox', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildDrawerItem(icon: Icons.analytics_outlined, title: 'System Resources', index: 0),
          _buildDrawerItem(icon: Icons.storage_outlined, title: 'Storage Info', index: 1),
          _buildDrawerItem(icon: Icons.receipt_long_outlined, title: 'Log Proxmox', index: 2),
          const Divider(color: Colors.white10, height: 32),
          
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            leading: const Icon(Icons.menu_book_outlined, color: Colors.white54, size: 24),
            title: const Text('Manual Book', style: TextStyle(color: Colors.white54, fontSize: 16, letterSpacing: 1.0)),
            onTap: () async {
              Navigator.pop(context);
              final Uri url = Uri.parse('https://cdn.sainzlab.my.id/sainzlab-storage/manualbook/manualbook-mymomox.pdf');
              if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Gagal membuka Manual Book'), backgroundColor: Colors.redAccent),
                  );
                }
              }
            },
          ),
          
          _buildDrawerItem(icon: Icons.settings_outlined, title: 'Settings', index: 3),
          
          const Spacer(),
          const Divider(color: Colors.white10, height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '© ${DateTime.now().year}Sainzlab | Support By RyakaDev',
              style: const TextStyle(color: Colors.white30, fontSize: 12, letterSpacing: 1.0),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawerItem({required IconData icon, required String title, required int index}) {
    bool isSelected = _currentIndex == index;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: Icon(icon, color: isSelected ? Colors.white : Colors.white54, size: 24),
      title: Text(title, style: TextStyle(color: isSelected ? Colors.white : Colors.white54, fontSize: 16, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, letterSpacing: 1.0)),
      tileColor: isSelected ? Colors.white.withOpacity(0.05) : Colors.transparent,
      onTap: () {
        Navigator.pop(context);
        if (_currentIndex != index) {
          setState(() { _currentIndex = index; if (index == 2) logs.clear(); else nodes.clear(); });
          if (index == 3) {
            _populateSettings();
          } else {
            fetchData(isInitialLoad: true);
          }
        }
      },
    );
  }

  // ==== PEMILIH HALAMAN ====
  Widget _buildBodyContent() {
    if (_currentIndex == 3) return _buildSettingsView();
    if (isLoading) return const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2));
    if (errorMessage.isNotEmpty && nodes.isEmpty && logs.isEmpty) return _buildErrorBox();
    
    switch (_currentIndex) {
      case 0: return _buildSystemResourcesView();
      case 1: return _buildStorageInfoView();
      case 2: return _buildLogProxmoxView();
      default: return _buildSystemResourcesView();
    }
  }

  // ==== HALAMAN 0: SYSTEM RESOURCES ====
  Widget _buildSystemResourcesView() {
    return RefreshIndicator(
      color: Colors.black, backgroundColor: Colors.white,
      onRefresh: () => fetchData(isInitialLoad: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeaderGreeting('Overview', 'System Resources'),
                  const SizedBox(height: 24),
                  _buildSectionTitle('NODES', Icons.dns_outlined),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(delegate: SliverChildBuilderDelegate((context, index) => _buildNodeCard(nodes[index]), childCount: nodes.length)),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  _buildSectionTitle('VIRTUAL MACHINES', Icons.memory_outlined),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(delegate: SliverChildBuilderDelegate((context, index) => _buildVmCard(vms[index]), childCount: vms.length)),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 40)),
        ],
      ),
    );
  }

  // ==== HALAMAN 1: STORAGE INFO ====
  Widget _buildStorageInfoView() {
    return RefreshIndicator(
      color: Colors.black, backgroundColor: Colors.white,
      onRefresh: () => fetchData(isInitialLoad: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeaderGreeting('Storage', 'Storage Info'),
                  const SizedBox(height: 24),
                  if (storages.isEmpty) const Center(child: Text("Tidak ada data storage", style: TextStyle(color: Colors.white54))),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(delegate: SliverChildBuilderDelegate((context, index) => _buildStorageCard(storages[index]), childCount: storages.length)),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 40)),
        ],
      ),
    );
  }

  // ==== HALAMAN 2: LOG PROXMOX ====
  Widget _buildLogProxmoxView() {
    return RefreshIndicator(
      color: Colors.black, backgroundColor: Colors.white,
      onRefresh: () => fetchData(isInitialLoad: true),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: logs.isEmpty ? 1 : logs.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_buildHeaderGreeting('Activity History', 'Log Proxmox'), const SizedBox(height: 24)]);
          return _buildLogCard(logs[index - 1]);
        },
      ),
    );
  }

  // ==== HALAMAN 3: SETTINGS (Dengan Input Port) ====
  Widget _buildSettingsView() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        _buildHeaderGreeting('Configuration', 'Settings'),
        const SizedBox(height: 32),
        
        _buildSectionTitle('SERVER CONNECTION', Icons.router_outlined),
        const SizedBox(height: 16),
        
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 6,
              child: _buildCustomTextField(
                controller: _ipController,
                label: 'IP Address',
                hint: 'e.g., 192.168.8.133',
                icon: Icons.language,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 4,
              child: _buildCustomTextField(
                controller: _portController,
                label: 'Port',
                hint: '8006',
                icon: Icons.settings_ethernet,
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        
        const SizedBox(height: 32),

        _buildSectionTitle('API CREDENTIALS', Icons.admin_panel_settings_outlined),
        const SizedBox(height: 16),
        _buildCustomTextField(
          controller: _userController,
          label: 'Proxmox User',
          hint: 'e.g., root@pam',
          icon: Icons.person_outline,
        ),
        const SizedBox(height: 16),
        _buildCustomTextField(
          controller: _tokenIdController,
          label: 'Token ID',
          hint: 'e.g., MobileApp',
          icon: Icons.badge_outlined,
        ),
        const SizedBox(height: 16),
        _buildCustomTextField(
          controller: _secretController,
          label: 'Secret Key (UUID)',
          hint: 'e.g., 5cd262a3-78c7-4d1c...',
          icon: Icons.key_outlined,
        ),
        
        const SizedBox(height: 48),
        SizedBox(
          width: double.infinity, height: 56,
          child: ElevatedButton(
            onPressed: _saveSettings,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white, foregroundColor: Colors.black,
              elevation: 4,
              shadowColor: Colors.white30,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.save_outlined, size: 20),
                SizedBox(width: 8),
                Text('SAVE SETTINGS', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 15)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildCustomTextField({required TextEditingController controller, required String label, required String hint, required IconData icon, TextInputType? keyboardType}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          style: const TextStyle(color: Colors.white, fontSize: 15),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.white24),
            prefixIcon: Icon(icon, color: Colors.white54, size: 20),
            filled: true, fillColor: const Color(0xFF0F0F0F),
            contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white10)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.tealAccent)),
          ),
        ),
      ],
    );
  }

  // ==== WIDGET BANTUAN GLOBAL ====
  Widget _buildHeaderGreeting(String subtitle, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 14, letterSpacing: 1.2)),
              if (_currentIndex != 3) Row(
                children: [
                  Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  const Text('LIVE', style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
                ],
              )
            ],
          ),
          const SizedBox(height: 4),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String appBarTitle = 'mymomox';
    if (_currentIndex == 1) appBarTitle = 'Storage';
    if (_currentIndex == 2) appBarTitle = 'Logs';
    if (_currentIndex == 3) appBarTitle = 'Settings';

    return Scaffold(
      drawer: _buildDrawer(),
      appBar: AppBar(
        backgroundColor: Colors.black, elevation: 0, toolbarHeight: 70,
        title: Row(
          children: [
            const Icon(Icons.dns, color: Colors.white, size: 28),
            const SizedBox(width: 12),
            Text(appBarTitle, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5, fontSize: 20, color: Colors.white)),
          ],
        ),
        actions: [
          if (_currentIndex != 3)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: IconButton(icon: const Icon(Icons.sync, color: Colors.white70), onPressed: () => fetchData(isInitialLoad: true), splashRadius: 24),
            ),
        ],
      ),
      body: _buildBodyContent(),
    );
  }

  Widget _buildErrorBox() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: const Color(0xFF1A0000), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.redAccent.withOpacity(0.3))),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              Text('Connection Lost\n$errorMessage', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, height: 1.5)),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => fetchData(isInitialLoad: true),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12)),
                child: const Text('RETRY', style: TextStyle(letterSpacing: 1.5)),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: Colors.white54, size: 20),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white54, letterSpacing: 2.0)),
      ],
    );
  }

  Widget _buildNodeCard(dynamic node) {
    bool isOnline = node['status'] == 'online';
    double cpuPct = node['cpu'] != null ? (node['cpu'] as num).toDouble() * 100 : 0.0;
    double ramPct = node['mem'] != null && node['maxmem'] != null ? ((node['mem'] as num).toDouble() / (node['maxmem'] as num).toDouble() * 100) : 0.0;
    double diskPct = node['disk'] != null && node['maxdisk'] != null ? ((node['disk'] as num).toDouble() / (node['maxdisk'] as num).toDouble() * 100) : 0.0;
    double ioDelayPct = node['io_delay'] != null ? (node['io_delay'] as num).toDouble() * 100 : 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(color: const Color(0xFF0F0F0F), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white10)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(node['node'].toString().toUpperCase(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1.0)),
                    const SizedBox(height: 6),
                    Text('UPTIME: ${formatUptime(node['uptime'])}', style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2)),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: isOnline ? Colors.tealAccent.withOpacity(0.1) : Colors.redAccent.withOpacity(0.1), borderRadius: BorderRadius.circular(20), border: Border.all(color: isOnline ? Colors.tealAccent.withOpacity(0.3) : Colors.redAccent.withOpacity(0.3))),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, size: 8, color: isOnline ? Colors.tealAccent : Colors.redAccent),
                      const SizedBox(width: 6),
                      Text(node['status'].toString().toUpperCase(), style: TextStyle(color: isOnline ? Colors.tealAccent : Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 10, letterSpacing: 1.0)),
                    ],
                  ),
                )
              ],
            ),
            const SizedBox(height: 24),
            _buildModernProgressBar('CPU', cpuPct, Colors.white),
            const SizedBox(height: 16),
            _buildModernProgressBar('RAM (${formatBytes(node['mem'])} / ${formatBytes(node['maxmem'])})', ramPct, Colors.white70),
            const SizedBox(height: 16),
            _buildModernProgressBar('STORAGE (${formatBytes(node['disk'])} / ${formatBytes(node['maxdisk'])})', diskPct, Colors.white30),
            const SizedBox(height: 16),
            _buildModernProgressBar('IO DELAY', ioDelayPct, ioDelayPct > 5.0 ? Colors.orangeAccent : Colors.amber),
          ],
        ),
      ),
    );
  }

  Widget _buildVmCard(dynamic vm) {
    bool isRunning = vm['status'] == 'running';
    String type = vm['type'];
    double cpuPct = isRunning && vm['cpu'] != null ? (vm['cpu'] as num).toDouble() * 100 : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _showVmDetails(context, vm),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(color: const Color(0xFF0F0F0F), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white10)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: isRunning ? Colors.white : Colors.white.withOpacity(0.05), shape: BoxShape.circle),
                child: Icon(type == 'qemu' ? Icons.computer : Icons.storage, size: 18, color: isRunning ? Colors.black : Colors.white54),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(vm['name'], style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: isRunning ? Colors.white : Colors.white54), overflow: TextOverflow.ellipsis)),
                        Text('#${vm['vmid']}', style: const TextStyle(color: Colors.white30, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(vm['node'].toString().toUpperCase(), style: const TextStyle(color: Colors.white54, fontSize: 11)),
                        const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.circle, size: 3, color: Colors.white30)),
                        Text(formatBytes(vm['maxmem']), style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(vm['status'].toString().toUpperCase(), style: TextStyle(color: isRunning ? Colors.tealAccent : Colors.white30, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
                  const SizedBox(height: 4),
                  if (isRunning)
                    Text('${cpuPct.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 12, color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.w600)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStorageCard(dynamic storage) {
    double diskUsed = storage['disk'] != null ? (storage['disk'] as num).toDouble() : 0.0;
    double maxDisk = storage['maxdisk'] != null ? (storage['maxdisk'] as num).toDouble() : 0.0;
    double pct = maxDisk > 0 ? (diskUsed / maxDisk * 100) : 0.0;
    bool isShared = storage['shared'] == 1;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFF0F0F0F), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isShared ? Icons.cloud_outlined : Icons.sd_storage_outlined, color: Colors.white, size: 20),
              const SizedBox(width: 12),
              Expanded(child: Text(storage['storage'], style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
                child: Text(storage['node'], style: const TextStyle(color: Colors.white54, fontSize: 10, letterSpacing: 1.0)),
              )
            ],
          ),
          const SizedBox(height: 16),
          _buildModernProgressBar('Usage (${formatBytes(diskUsed)} / ${formatBytes(maxDisk)})', pct, pct > 80 ? Colors.redAccent : Colors.tealAccent),
        ],
      ),
    );
  }

  Widget _buildLogCard(dynamic log) {
    bool isError = log['msg'].toString().toLowerCase().contains('error') || log['msg'].toString().toLowerCase().contains('fail');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: isError ? Colors.redAccent.withOpacity(0.05) : const Color(0xFF0F0F0F), borderRadius: BorderRadius.circular(8), border: Border.all(color: isError ? Colors.redAccent.withOpacity(0.3) : Colors.white10)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(isError ? Icons.warning_amber_rounded : Icons.info_outline, color: isError ? Colors.redAccent : Colors.white30),
        title: Text(log['msg'], style: TextStyle(color: isError ? Colors.red.shade200 : Colors.white, fontSize: 13)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6.0),
          child: Row(
            children: [
              Text(formatTimestamp(log['time']), style: const TextStyle(color: Colors.white30, fontSize: 11)),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.circle, size: 3, color: Colors.white10)),
              Text('User: ${log['user']}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModernProgressBar(String label, double percentage, Color color, {String? customTrailingText}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500)),
            Text(customTrailingText ?? '${percentage.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          ],
        ),
        const SizedBox(height: 8),
        Stack(
          children: [
            Container(height: 4, decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(2))),
            AnimatedContainer(
              duration: const Duration(milliseconds: 500), curve: Curves.easeInOut,
              width: MediaQuery.of(context).size.width * ((percentage / 100).clamp(0.0, 1.0)) * 0.85, 
              height: 4, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2), boxShadow: [BoxShadow(color: color.withOpacity(0.3), blurRadius: 4, offset: const Offset(0, 2))]),
            ),
          ],
        ),
      ],
    );
  }

  void _showVmDetails(BuildContext context, dynamic vm) {
    bool isRunning = vm['status'] == 'running';
    double cpuPct = isRunning && vm['cpu'] != null ? (vm['cpu'] as num).toDouble() * 100 : 0.0;
    double ramPct = isRunning && vm['mem'] != null && vm['maxmem'] != null ? ((vm['mem'] as num).toDouble() / (vm['maxmem'] as num).toDouble() * 100) : 0.0;
    double diskUsed = vm['disk'] != null ? (vm['disk'] as num).toDouble() : 0.0;
    double maxDisk = vm['maxdisk'] != null ? (vm['maxdisk'] as num).toDouble() : 0.0;
    bool isDiskReadable = diskUsed > 0.0; 
    double diskPct = (isRunning && maxDisk > 0 && isDiskReadable) ? (diskUsed / maxDisk * 100) : 0.0;

    showModalBottomSheet(
      context: context, backgroundColor: Colors.transparent, isScrollControlled: true,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(color: Color(0xFF0F0F0F), borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)), border: Border(top: BorderSide(color: Colors.white10))),
          child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 24), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: isRunning ? Colors.white : Colors.white.withOpacity(0.05), shape: BoxShape.circle),
                    child: Icon(vm['type'] == 'qemu' ? Icons.computer : Icons.storage, size: 24, color: isRunning ? Colors.black : Colors.white54),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(vm['name'], style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                        const SizedBox(height: 4),
                        Text('ID: #${vm['vmid']} • Node: ${vm['node']}', style: const TextStyle(color: Colors.white54, fontSize: 13)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: isRunning ? Colors.tealAccent.withOpacity(0.1) : Colors.white10, borderRadius: BorderRadius.circular(20)),
                    child: Text(vm['status'].toString().toUpperCase(), style: TextStyle(color: isRunning ? Colors.tealAccent : Colors.white54, fontWeight: FontWeight.bold, fontSize: 10, letterSpacing: 1.0)),
                  )
                ],
              ),
              const SizedBox(height: 32),
              
              if (isRunning) ...[
                _buildModernProgressBar('CPU Usage', cpuPct, Colors.white),
                const SizedBox(height: 20),
                _buildModernProgressBar('RAM (${formatBytes(vm['mem'])} / ${formatBytes(vm['maxmem'])})', ramPct, Colors.white70),
                const SizedBox(height: 20),
                _buildModernProgressBar(isDiskReadable ? 'Storage (${formatBytes(diskUsed)} / ${formatBytes(maxDisk)})' : 'Storage (Allocated: ${formatBytes(maxDisk)})', diskPct, Colors.white30, customTrailingText: isDiskReadable ? null : 'Unreadable'),
                const SizedBox(height: 24),
                Center(child: Text('UPTIME: ${formatUptime(vm['uptime'])}', style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2))),
              ] else ...[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('Mesin sedang mati (Offline).\nDetail sumber daya tidak tersedia.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, height: 1.5))),
                )
              ],
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}