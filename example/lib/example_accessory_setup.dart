import 'package:foundation_ble/foundation_ble.dart';

const String primeAccessoryId = 'passport-prime-ble';
const String primeAccessoryDisplayName = 'Passport Prime';
const String primeAccessoryNameSubstring = 'Passport Prime';
const String primeAccessoryServiceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const String primeAccessoryImageAsset = 'assets/prime_dark_midnight_bronze.png';

const List<IosAccessoryPickerItem> exampleIosPickerItems =
    <IosAccessoryPickerItem>[
      IosAccessoryPickerItem(
        id: primeAccessoryId,
        name: primeAccessoryDisplayName,
        imageAsset: primeAccessoryImageAsset,
        descriptor: IosAccessoryDiscoveryDescriptor(
          bluetoothNameSubstring: primeAccessoryNameSubstring,
          bluetoothServiceUuid: primeAccessoryServiceUuid,
        ),
      ),
    ];
