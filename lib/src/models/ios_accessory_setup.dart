import 'dart:typed_data';

enum IosAccessoryDiscoveryRange { defaultRange, immediate }

enum IosBluetoothNameCompareOption {
  caseInsensitive,
  literal,
  backwards,
  anchored,
  numeric,
  diacriticInsensitive,
  widthInsensitive,
  forcedOrdering,
  regularExpression,
}

class IosAccessoryDiscoveryDescriptor {
  const IosAccessoryDiscoveryDescriptor({
    this.bluetoothCompanyIdentifier,
    this.bluetoothManufacturerData,
    this.bluetoothManufacturerDataMask,
    this.bluetoothNameCompareOptions = const <IosBluetoothNameCompareOption>{},
    this.bluetoothNameSubstring,
    this.bluetoothRange = IosAccessoryDiscoveryRange.defaultRange,
    this.bluetoothServiceData,
    this.bluetoothServiceDataMask,
    this.bluetoothServiceUuid,
  });

  final int? bluetoothCompanyIdentifier;
  final Uint8List? bluetoothManufacturerData;
  final Uint8List? bluetoothManufacturerDataMask;
  final Set<IosBluetoothNameCompareOption> bluetoothNameCompareOptions;
  final String? bluetoothNameSubstring;
  final IosAccessoryDiscoveryRange bluetoothRange;
  final Uint8List? bluetoothServiceData;
  final Uint8List? bluetoothServiceDataMask;
  final String? bluetoothServiceUuid;

  Map<String, Object?> toMap() {
    _validate();

    return <String, Object?>{
      if (bluetoothCompanyIdentifier != null)
        'bluetoothCompanyIdentifier': bluetoothCompanyIdentifier,
      if (bluetoothManufacturerData != null)
        'bluetoothManufacturerData': bluetoothManufacturerData,
      if (bluetoothManufacturerDataMask != null)
        'bluetoothManufacturerDataMask': bluetoothManufacturerDataMask,
      if (bluetoothNameCompareOptions.isNotEmpty)
        'bluetoothNameCompareOptions':
            bluetoothNameCompareOptions
                .map((option) => option._wireName)
                .toList(growable: false)
              ..sort(),
      if (bluetoothNameSubstring != null)
        'bluetoothNameSubstring': bluetoothNameSubstring,
      'bluetoothRange': bluetoothRange._wireName,
      if (bluetoothServiceData != null)
        'bluetoothServiceData': bluetoothServiceData,
      if (bluetoothServiceDataMask != null)
        'bluetoothServiceDataMask': bluetoothServiceDataMask,
      if (bluetoothServiceUuid != null)
        'bluetoothServiceUuid': bluetoothServiceUuid,
    };
  }

  void _validate() {
    final hasBluetoothFilter =
        bluetoothCompanyIdentifier != null ||
        bluetoothManufacturerData != null ||
        bluetoothNameSubstring != null ||
        bluetoothServiceData != null ||
        bluetoothServiceUuid != null;
    if (!hasBluetoothFilter) {
      throw ArgumentError(
        'At least one Bluetooth discovery filter must be provided.',
      );
    }

    if (bluetoothCompanyIdentifier != null &&
        (bluetoothCompanyIdentifier! < 0 ||
            bluetoothCompanyIdentifier! > 0xFFFF)) {
      throw ArgumentError.value(
        bluetoothCompanyIdentifier,
        'bluetoothCompanyIdentifier',
        'must be between 0 and 65535',
      );
    }

    if (bluetoothManufacturerDataMask != null &&
        bluetoothManufacturerData == null) {
      throw ArgumentError(
        'bluetoothManufacturerDataMask requires bluetoothManufacturerData.',
      );
    }

    if (bluetoothServiceDataMask != null && bluetoothServiceData == null) {
      throw ArgumentError(
        'bluetoothServiceDataMask requires bluetoothServiceData.',
      );
    }

    if (bluetoothManufacturerData != null &&
        bluetoothManufacturerDataMask != null &&
        bluetoothManufacturerData!.lengthInBytes !=
            bluetoothManufacturerDataMask!.lengthInBytes) {
      throw ArgumentError(
        'bluetoothManufacturerData and bluetoothManufacturerDataMask must have the same length.',
      );
    }

    if (bluetoothServiceData != null &&
        bluetoothServiceDataMask != null &&
        bluetoothServiceData!.lengthInBytes !=
            bluetoothServiceDataMask!.lengthInBytes) {
      throw ArgumentError(
        'bluetoothServiceData and bluetoothServiceDataMask must have the same length.',
      );
    }

    if (bluetoothNameCompareOptions.isNotEmpty &&
        (bluetoothNameSubstring == null || bluetoothNameSubstring!.isEmpty)) {
      throw ArgumentError(
        'bluetoothNameCompareOptions requires bluetoothNameSubstring.',
      );
    }

    if (bluetoothNameSubstring != null && bluetoothNameSubstring!.isEmpty) {
      throw ArgumentError.value(
        bluetoothNameSubstring,
        'bluetoothNameSubstring',
        'must not be empty',
      );
    }

    if (bluetoothServiceUuid != null && bluetoothServiceUuid!.isEmpty) {
      throw ArgumentError.value(
        bluetoothServiceUuid,
        'bluetoothServiceUuid',
        'must not be empty',
      );
    }
  }

  @override
  String toString() {
    return 'IosAccessoryDiscoveryDescriptor(bluetoothCompanyIdentifier: $bluetoothCompanyIdentifier, bluetoothNameSubstring: $bluetoothNameSubstring, bluetoothRange: $bluetoothRange, bluetoothServiceUuid: $bluetoothServiceUuid)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is IosAccessoryDiscoveryDescriptor &&
            runtimeType == other.runtimeType &&
            bluetoothCompanyIdentifier == other.bluetoothCompanyIdentifier &&
            _bytesEqual(
              bluetoothManufacturerData,
              other.bluetoothManufacturerData,
            ) &&
            _bytesEqual(
              bluetoothManufacturerDataMask,
              other.bluetoothManufacturerDataMask,
            ) &&
            _setEquals(
              bluetoothNameCompareOptions,
              other.bluetoothNameCompareOptions,
            ) &&
            bluetoothNameSubstring == other.bluetoothNameSubstring &&
            bluetoothRange == other.bluetoothRange &&
            _bytesEqual(bluetoothServiceData, other.bluetoothServiceData) &&
            _bytesEqual(
              bluetoothServiceDataMask,
              other.bluetoothServiceDataMask,
            ) &&
            bluetoothServiceUuid == other.bluetoothServiceUuid;
  }

  @override
  int get hashCode {
    return Object.hash(
      bluetoothCompanyIdentifier,
      _bytesHash(bluetoothManufacturerData),
      _bytesHash(bluetoothManufacturerDataMask),
      Object.hashAll(
        bluetoothNameCompareOptions
            .map((option) => option._wireName)
            .toList(growable: false)
          ..sort(),
      ),
      bluetoothNameSubstring,
      bluetoothRange,
      _bytesHash(bluetoothServiceData),
      _bytesHash(bluetoothServiceDataMask),
      bluetoothServiceUuid,
    );
  }
}

class IosAccessoryPickerItem {
  const IosAccessoryPickerItem({
    required this.id,
    required this.name,
    required this.descriptor,
    this.imageAsset,
    this.imagePackage,
  });

  final String id;
  final String name;
  final IosAccessoryDiscoveryDescriptor descriptor;
  final String? imageAsset;
  final String? imagePackage;

  Map<String, Object?> toMap() {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    if (imagePackage != null && (imageAsset == null || imageAsset!.isEmpty)) {
      throw ArgumentError('imagePackage requires imageAsset to be provided.');
    }

    return <String, Object?>{
      'id': id,
      'name': name,
      'descriptor': descriptor.toMap(),
      if (imageAsset != null) 'imageAsset': imageAsset,
      if (imagePackage != null) 'imagePackage': imagePackage,
    };
  }

  @override
  String toString() {
    return 'IosAccessoryPickerItem(id: $id, name: $name, imageAsset: $imageAsset, imagePackage: $imagePackage, descriptor: $descriptor)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is IosAccessoryPickerItem &&
            runtimeType == other.runtimeType &&
            id == other.id &&
            name == other.name &&
            descriptor == other.descriptor &&
            imageAsset == other.imageAsset &&
            imagePackage == other.imagePackage;
  }

  @override
  int get hashCode {
    return Object.hash(id, name, descriptor, imageAsset, imagePackage);
  }
}

class IosAccessorySetupResult {
  const IosAccessorySetupResult({required this.deviceId, this.pickerItemId});

  factory IosAccessorySetupResult.fromMap(Map<String, dynamic> map) {
    return IosAccessorySetupResult(
      deviceId: map['deviceId'] as String? ?? '',
      pickerItemId: map['pickerItemId'] as String?,
    );
  }

  final String deviceId;
  final String? pickerItemId;

  @override
  String toString() {
    return 'IosAccessorySetupResult(deviceId: $deviceId, pickerItemId: $pickerItemId)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is IosAccessorySetupResult &&
            runtimeType == other.runtimeType &&
            deviceId == other.deviceId &&
            pickerItemId == other.pickerItemId;
  }

  @override
  int get hashCode => Object.hash(deviceId, pickerItemId);
}

extension on IosAccessoryDiscoveryRange {
  String get _wireName {
    return switch (this) {
      IosAccessoryDiscoveryRange.defaultRange => 'default',
      IosAccessoryDiscoveryRange.immediate => 'immediate',
    };
  }
}

extension on IosBluetoothNameCompareOption {
  String get _wireName {
    return switch (this) {
      IosBluetoothNameCompareOption.caseInsensitive => 'caseInsensitive',
      IosBluetoothNameCompareOption.literal => 'literal',
      IosBluetoothNameCompareOption.backwards => 'backwards',
      IosBluetoothNameCompareOption.anchored => 'anchored',
      IosBluetoothNameCompareOption.numeric => 'numeric',
      IosBluetoothNameCompareOption.diacriticInsensitive =>
        'diacriticInsensitive',
      IosBluetoothNameCompareOption.widthInsensitive => 'widthInsensitive',
      IosBluetoothNameCompareOption.forcedOrdering => 'forcedOrdering',
      IosBluetoothNameCompareOption.regularExpression => 'regularExpression',
    };
  }
}

bool _bytesEqual(Uint8List? left, Uint8List? right) {
  if (left == null || right == null) {
    return left == right;
  }
  if (left.lengthInBytes != right.lengthInBytes) {
    return false;
  }
  for (var index = 0; index < left.lengthInBytes; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

int _bytesHash(Uint8List? bytes) {
  if (bytes == null) {
    return 0;
  }
  return Object.hashAll(bytes);
}

bool _setEquals<T>(Set<T> left, Set<T> right) {
  if (left.length != right.length) {
    return false;
  }
  for (final value in left) {
    if (!right.contains(value)) {
      return false;
    }
  }
  return true;
}
