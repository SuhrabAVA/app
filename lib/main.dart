import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'admin_panel.dart';
import 'firebase_options.dart';
import 'modules/warehouse/warehouse_provider.dart';
import 'modules/warehouse/supplier_provider.dart';
import 'modules/personnel/personnel_provider.dart';
import 'my_app.dart';
import 'modules/orders/orders_provider.dart';
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WarehouseProvider()),
        ChangeNotifierProvider(create: (_) => PersonnelProvider()),
        ChangeNotifierProvider(create: (_) => OrdersProvider()),
        ChangeNotifierProvider(create: (_) => SupplierProvider()),
      ],
      child: const MyApp(),
    ),
  );
}
