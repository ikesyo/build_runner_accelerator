import 'package:json_annotation/json_annotation.dart';

part 'model_256.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model256 {
  const Model256({required this.id, required this.value});

  final int id;
  final String value;

  factory Model256.fromJson(Map<String, dynamic> json) =>
      _$Model256FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model256ToJson(this);
}
