import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/settings_screen.dart';
import 'screens/usage_screen.dart';
import 'screens/work_screen.dart';
import 'settings.dart';

void main() {
  final state = AppState(SettingsStore());
  runApp(AgentMonitorApp(state: state));
  state.init();
}

class AgentMonitorApp extends StatelessWidget {
  const AgentMonitorApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Agent Monitor',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
    home: HomePage(state: state),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final state = widget.state;
      final pages = [WorkScreen(state: state), UsageScreen(state: state), SettingsScreen(state: state)];
      final tab = state.settings.configured ? _tab : 2;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Agent Monitor'),
          actions: [
            if (state.loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: state.refresh),
          ],
        ),
        body: pages[tab],
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.assignment_ind_outlined), label: 'Work'),
            NavigationDestination(icon: Icon(Icons.data_usage), label: 'Usage'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
          ],
        ),
      );
    },
  );
}
