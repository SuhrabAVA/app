import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'warehouse_provider.dart';

class ShipmentForm extends StatefulWidget {
  const ShipmentForm({super.key});

  @override
  State<ShipmentForm> createState() => _ShipmentFormState();
}

class _ShipmentFormState extends State<ShipmentForm> {
  final _formKey = GlobalKey<FormState>();
  final _receiverController = TextEditingController();
  final _productController = TextEditingController();
  final _quantityController = TextEditingController();
  final _docNumberController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<WarehouseProvider>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Регистрация отгрузки')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _receiverController,
                decoration: const InputDecoration(labelText: 'Получатель'),
                validator: (value) =>
                    value!.isEmpty ? 'Введите получателя' : null,
              ),
              TextFormField(
                controller: _productController,
                decoration: const InputDecoration(labelText: 'Наименование ТМЦ'),
                validator: (value) =>
                    value!.isEmpty ? 'Введите наименование' : null,
              ),
              TextFormField(
                controller: _quantityController,
                decoration: const InputDecoration(labelText: 'Количество'),
                keyboardType: TextInputType.number,
                validator: (value) =>
                    value!.isEmpty ? 'Введите количество' : null,
              ),
              TextFormField(
                controller: _docNumberController,
                decoration:
                    const InputDecoration(labelText: 'Сопроводительный документ'),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  if (_formKey.currentState!.validate()) {
                    provider.registerShipment(
                      receiver: _receiverController.text,
                      product: _productController.text,
                      quantity: double.parse(_quantityController.text),
                      document: _docNumberController.text,
                    );

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Отгрузка зарегистрирована')),
                    );
                    _formKey.currentState!.reset();
                  }
                },
                child: const Text('Провести'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
