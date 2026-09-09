import 'package:json_annotation/json_annotation.dart';

part 'model_351.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model351 {
  const Model351({required this.id, required this.value});

  final int id;
  final String value;

  factory Model351.fromJson(Map<String, dynamic> json) =>
      _$Model351FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model351ToJson(this);
}
