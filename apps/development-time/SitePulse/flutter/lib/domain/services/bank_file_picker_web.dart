import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

class PickedBankFile {
  final String name;
  final Uint8List bytes;

  PickedBankFile({required this.name, required this.bytes});
}

Future<PickedBankFile?> pickBankFile() async {
  final completer = Completer<PickedBankFile?>();
  final uploadInput = html.FileUploadInputElement();
  uploadInput.accept = '.xlsx,.xls,.csv,.txt,.sta';
  uploadInput.click();

  uploadInput.onChange.listen((e) {
    final files = uploadInput.files;
    if (files != null && files.isNotEmpty) {
      final file = files[0];
      final reader = html.FileReader();
      reader.onLoadEnd.listen((e) {
        if (reader.result != null) {
          final rawResult = reader.result;
          Uint8List bytes;
          if (rawResult is Uint8List) {
            bytes = rawResult;
          } else if (rawResult is ByteBuffer) {
            bytes = Uint8List.view(rawResult);
          } else {
            bytes = Uint8List.fromList(List<int>.from(rawResult as dynamic));
          }
          completer.complete(PickedBankFile(name: file.name, bytes: bytes));
        } else {
          completer.complete(null);
        }
      });
      reader.readAsArrayBuffer(file);
    } else {
      completer.complete(null);
    }
  });

  return completer.future;
}
