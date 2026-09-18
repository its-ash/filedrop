/// Mirrors `filedrop_core::discovery::DiscoveredDevice` /
/// `filedrop_ffi::api::DiscoveredDeviceDto` on the Rust side.
class Device {
  final String deviceId;
  final String name;
  final String address;
  final int port;
  final String platform;
  final bool paired;

  const Device({
    required this.deviceId,
    required this.name,
    required this.address,
    required this.port,
    required this.platform,
    required this.paired,
  });

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        deviceId: json['device_id'] as String,
        name: json['name'] as String,
        address: json['address'] as String,
        port: json['port'] as int,
        platform: json['platform'] as String,
        paired: json['paired'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'name': name,
        'address': address,
        'port': port,
        'platform': platform,
        'paired': paired,
      };

  Device copyWith({bool? paired}) => Device(
        deviceId: deviceId,
        name: name,
        address: address,
        port: port,
        platform: platform,
        paired: paired ?? this.paired,
      );
}
