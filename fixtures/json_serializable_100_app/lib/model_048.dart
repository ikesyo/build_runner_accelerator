import 'package:json_annotation/json_annotation.dart';

part 'model_048.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model048 {
  const Model048({required this.id, required this.value});

  final int id;
  final String value;

  factory Model048.fromJson(Map<String, dynamic> json) =>
      _$Model048FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model048ToJson(this);
}
