import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';

String sha256Hash(String input) {
  final bytes = utf8.encode(input);
  final digest = sha256.convert(bytes);
  return digest.toString();
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Authorization App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const PermissionPage(),
    );
  }
}

class PermissionPage extends StatefulWidget {
  const PermissionPage({super.key});

  @override
  State<PermissionPage> createState() => _PermissionPageState();
}

Future<int> getAndroidVersion() async {
  if (Platform.isAndroid) {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    return androidInfo.version.sdkInt;
  }
  return 0;
}

class _PermissionPageState extends State<PermissionPage> {
  String? authKey;
  bool isLoading = true;
  Timer? _fileCheckTimer;

  @override
  void initState() {
    super.initState();
    requestPermissionAndInit();
    _fileCheckTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _checkKeyFile(),
    );
  }

  @override
  void dispose() {
    _fileCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> requestPermissionAndInit() async {
    try {
      if (Platform.isAndroid) {
        if (!mounted) return;

        final androidVersion = await getAndroidVersion();
        if (androidVersion == 0) {
          throw 'حدث خطأ في التعرف على إصدار النظام';
        }

        int attempts = 0;
        while (attempts < 3) {
          final granted = await requestPermissions(androidVersion);
          if (granted) break;
          attempts++;
          if (attempts == 3) {
            throw 'لم يتم منح الصلاحيات المطلوبة';
          }
          await Future.delayed(const Duration(seconds: 1));
        }
      }

      final key = await getOrCreateKey();
      if (mounted) {
        setState(() {
          authKey = key;
          isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: Colors.red,
        ),
      );
      await Future.delayed(const Duration(seconds: 2));
      SystemNavigator.pop();
    }
  }

  Future<bool> requestPermissions(int androidVersion) async {
    try {
      if (androidVersion < 33) {
        // Less than Android 13
        var status = await Permission.storage.request();
        return status.isGranted;
      } else if (androidVersion == 33) {
        // Android 13 specifically
        var mediaStatus = await Permission.photos.request();
        var storageStatus = await Permission.storage.request();
        return mediaStatus.isGranted && storageStatus.isGranted;
      } else {
        // Android 14 and above
        var status = await Permission.manageExternalStorage.request();
        return status.isGranted;
      }
    } catch (e) {
      print('خطأ في طلب الصلاحيات: $e');
      return false;
    }
  }

  Future<void> _checkKeyFile() async {
    final directory = Directory('/storage/emulated/0/Android/.ATHFiles');
    final file = File('${directory.path}/.ATH.enc');

    if (!await file.exists()) {
      await Logger.log('تم اكتشاف فقدان الملف');
      if (mounted) {
        showError(context, 'تم اكتشاف مشكلة في ملف المفتاح');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (authKey != null) {
      return HomePage(authKey: authKey!);
    }

    return Scaffold(
      body: Center(
        child: isLoading
            ? const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 20),
                  Text(
                    'جاري التحقق من الصلاحيات...',
                    style: TextStyle(fontSize: 16),
                  ),
                ],
              )
            : const SizedBox(), // لن يتم عرض هذا أبداً لأن التطبيق سيغلق إذا تم رفض الإذن
      ),
    );
  }
}

Future<String> getOrCreateKey() async {
  if (Platform.isAndroid) {
    final androidVersion = await getAndroidVersion();

    if (androidVersion < 33) {
      // أقل من Android 13
      var status = await Permission.storage.status;
      if (!status.isGranted) {
        throw 'يرجى منح التطبيق صلاحية';
      }
    } else if (androidVersion == 33) {
      // Android 13 تحديداً
      var mediaStatus = await Permission.photos.status;
      var storageStatus = await Permission.storage.status;
      if (!mediaStatus.isGranted || !storageStatus.isGranted) {
        mediaStatus = await Permission.photos.request();
        storageStatus = await Permission.storage.request();
        if (!mediaStatus.isGranted || !storageStatus.isGranted) {
          throw 'يجب السماح بصلاحيات لاستخدام التطبيق';
        }
      }
    } else {
      // Android 14 وما فوق
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        status = await Permission.manageExternalStorage.request();
        if (!status.isGranted) {
          throw 'يجب السماح بصلاحيات لاستخدام التطبيق';
        }
      }
    }

    final directory = Directory('/storage/emulated/0/Android/.ATHFiles');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
      final nomedia = File('${directory.path}/.nomedia');
      await nomedia.create();
    }
    return handleKeyFile(directory);
  } else {
    final directory = await getApplicationDocumentsDirectory();
    return handleKeyFile(directory);
  }
}

Future<String> handleKeyFile(Directory directory) async {
  try {
    final file = File('${directory.path}/.ATH.enc');

    if (await file.exists()) {
      try {
        return await decryptFile(file);
      } catch (e) {
        // If decryption fails, try to create a new key
        print('Failed to read file: $e');
        final key = generateRandomKey();
        await encryptAndSaveKey(key, file);
        await backupKey(key, directory);
        return key;
      }
    } else {
      // إنشاء المجلد إذا لم يكن موجوداً
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final key = generateRandomKey();
      await encryptAndSaveKey(key, file);
      await backupKey(key, directory);
      return key;
    }
  } catch (e) {
    throw 'حدث خطأ في معالجة الملف: $e';
  }
}

String generateRandomKey() {
  String key;
  do {
    key = _generateKey();
  } while (!isValidKey(key));
  return key;
}

Future<void> encryptAndSaveKey(String key, File file) async {
  try {
    final encryptionKey = encrypt.Key.fromSecureRandom(32);
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter = encrypt.Encrypter(encrypt.AES(encryptionKey));

    final encrypted = encrypter.encrypt(key, iv: iv);

    final Map<String, String> data = {
      'key': encrypted.base64,
      'iv': iv.base64,
      'encryption_key': encryptionKey.base64,
      'timestamp': DateTime.now().toIso8601String(),
      'version': '1.0',
    };

    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(json.encode(data));
    await tempFile.rename(file.path);
  } catch (e) {
    throw 'حدث خطأ في تشفير المفتاح: $e';
  }
}

Future<String> decryptFile(File file) async {
  final content = await file.readAsString();
  final data = json.decode(content);

  final encryptionKey = encrypt.Key.fromBase64(data['encryption_key']);
  final iv = encrypt.IV.fromBase64(data['iv']);
  final encrypter = encrypt.Encrypter(encrypt.AES(encryptionKey));

  final decrypted = encrypter.decrypt64(data['key'], iv: iv);
  return decrypted;
}

Future<void> backupKey(String key, Directory directory) async {
  try {
    final backupFile = File('${directory.path}/.ATH.backup');
    await encryptAndSaveKey(key, backupFile);
  } catch (e) {
    print('فشل إنشاء النسخة الاحتياطية: $e');
  }
}

class HomePage extends StatelessWidget {
  final String authKey;

  const HomePage({super.key, required this.authKey});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('مفتاح التفعيل'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Card(
                elevation: 5,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Text(
                        'مفتاح التفعيل الخاص بك:',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 15),
                      SelectableText(
                        authKey,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 200,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 30,
                      vertical: 15,
                    ),
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: authKey));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('تم نسخ المفتاح بنجاح'),
                        behavior: SnackBarBehavior.floating,
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('نسخ المفتاح'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool isValidKey(String key) {
  if (key.length != 12) return false;

  bool hasUpperCase = key.contains(RegExp(r'[A-Z]'));
  bool hasLowerCase = key.contains(RegExp(r'[a-z]'));
  bool hasDigits = key.contains(RegExp(r'[0-9]'));
  bool hasSpecialChar = key.contains(RegExp(r'[!@#\$%^&*()]'));

  return hasUpperCase && hasLowerCase && hasDigits && hasSpecialChar;
}

String _generateKey() {
  final random = Random.secure();
  final chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%^&*()';
  return List.generate(12, (index) => chars[random.nextInt(chars.length)])
      .join();
}

Future<void> checkStorage() async {
  try {
    final directory = Directory('/storage/emulated/0/Android/.ATHFiles');
    final stat = await directory.statSync();
    final freeSpace = stat.size;

    if (freeSpace < 1024 * 1024) {
      // Less than 1 MB
      throw 'Insufficient storage space';
    }
  } catch (e) {
    print('Error checking storage space: $e');
  }
}

Future<T> retryOperation<T>(Future<T> Function() operation,
    {int maxAttempts = 3}) async {
  int attempts = 0;
  while (attempts < maxAttempts) {
    try {
      return await operation();
    } catch (e) {
      attempts++;
      if (attempts == maxAttempts) rethrow;
      await Future.delayed(Duration(seconds: 1));
    }
  }
  throw 'فشلت العملية بعد $maxAttempts محاولات';
}

Future<void> secureKey(String key, Directory directory) async {
  final salt = encrypt.Key.fromSecureRandom(16).base64;
  final hash = await compute<String, String>(sha256Hash, key + salt);

  final secureData = {
    'hash': hash,
    'salt': salt,
    'created_at': DateTime.now().toIso8601String(),
    'device_info': await getDeviceInfo(),
  };

  final secureFile = File('${directory.path}/.ATH.secure');
  await secureFile.writeAsString(json.encode(secureData));
}

Future<Map<String, String>> getDeviceInfo() async {
  if (Platform.isAndroid) {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    return {
      'device': androidInfo.device,
      'brand': androidInfo.brand,
      'model': androidInfo.model,
      'id': androidInfo.id,
      'androidVersion': androidInfo.version.release,
    };
  }
  return {};
}

class Logger {
  static final File _logFile =
      File('/storage/emulated/0/Android/.ATHFiles/.log');

  static Future<void> log(String message) async {
    final timestamp = DateTime.now().toIso8601String();
    final entry = '$timestamp: $message\n';

    try {
      await _logFile.writeAsString(entry, mode: FileMode.append);
    } catch (e) {
      print('Failed to write log: $e');
    }
  }

  static Future<void> clearLogs() async {
    try {
      if (await _logFile.exists()) {
        await _logFile.delete();
      }
    } catch (e) {
      print('Failed to clear logs: $e');
    }
  }
}

Future<String?> tryRecoverKey(Directory directory) async {
  try {
    // محاولة استعادة من النسخة الاحتياطية
    final backupFile = File('${directory.path}/.ATH.backup');
    if (await backupFile.exists()) {
      return await decryptFile(backupFile);
    }

    // محاولة البحث عن نسخ قديمة
    final files = await directory.list().toList();
    for (var file in files) {
      if (file.path.endsWith('.enc') || file.path.endsWith('.backup')) {
        try {
          return await decryptFile(file as File);
        } catch (_) {
          continue;
        }
      }
    }
  } catch (e) {
    await Logger.log('Key recovery failed: $e');
  }
  return null;
}

void showError(BuildContext context, String message) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('خطأ'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            SystemNavigator.pop();
          },
          child: const Text('إغلاق'),
        ),
      ],
    ),
  );
}
