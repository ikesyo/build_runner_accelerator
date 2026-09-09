import 'package:json_annotation/json_annotation.dart';

part 'model_228.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model228 {
  const Model228({required this.id, required this.value});

  final int id;
  final String value;

  factory Model228.fromJson(Map<String, dynamic> json) =>
      _$Model228FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model228ToJson(this);
}
