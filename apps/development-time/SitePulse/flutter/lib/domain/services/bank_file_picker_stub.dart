import 'dart:typed_data';

class PickedBankFile {
  final String name;
  final Uint8List bytes;

  PickedBankFile({required this.name, required this.bytes});
}

Future<PickedBankFile?> pickBankFile({String? accept}) async {
  return null;
}
