import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'warehouse_provider.dart';

class ReturnForm extends StatefulWidget {
  const ReturnForm({super.key});

  @override
  State<ReturnForm> createState() => _ReturnFormState();
}

class _ReturnFormState extends State<ReturnForm> {
  final _formKey = GlobalKey<FormState>();
  final _fromToController = TextEditingController();
  final _productController = TextEditingController();
  final _quantityController = TextEditingController();
  final _reasonController = TextEditingController();
  final _noteController = TextEditingController();

  bool _returnToSupplier = false;

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<WarehouseProvider>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Возврат ТМЦ')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              SwitchListTile(
                title: const Text('Возврат поставщику?'),
                value: _returnToSupplier,
                onChanged: (val) => setState(() => _returnToSupplier = val),
              ),
              TextFormField(
                controller: _fromToController,
                decoration: InputDecoration(
                  labelText:
                      _returnToSupplier ? 'Кому возврат' : 'От кого возврат',
                ),
                validator: (value) =>
                    value!.isEmpty ? 'Введите участника возврата' : null,
              ),
              TextFormField(
                controller: _productController,
                decoration: const InputDecoration(labelText: 'Тип ТМЦ'),
                validator: (value) =>
                    value!.isEmpty ? 'Введите тип ТМЦ' : null,
              ),
              TextFormField(
                controller: _quantityController,
                decoration: const InputDecoration(labelText: 'Количество'),
                keyboardType: TextInputType.number,
                validator: (value) =>
                    value!.isEmpty ? 'Введите количество' : null,
              ),
              TextFormField(
                controller: _reasonController,
                decoration: const InputDecoration(labelText: 'Причина возврата'),
              ),
              TextFormField(
                controller: _noteController,
                decoration: const InputDecoration(labelText: 'Примечание'),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  if (_formKey.currentState!.validate()) {
                    provider.registerReturn(
                      isToSupplier: _returnToSupplier,
                      partner: _fromToController.text,
                      product: _productController.text,
                      quantity: double.parse(_quantityController.text),
                      reason: _reasonController.text,
                      note: _noteController.text,
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Возврат зарегистрирован')),
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
