import 'package:json_annotation/json_annotation.dart';

part 'model_127.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model127 {
  const Model127({required this.id, required this.value});

  final int id;
  final String value;

  factory Model127.fromJson(Map<String, dynamic> json) =>
      _$Model127FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model127ToJson(this);
}
