import 'package:json_annotation/json_annotation.dart';

part 'model_335.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model335 {
  const Model335({required this.id, required this.value});

  final int id;
  final String value;

  factory Model335.fromJson(Map<String, dynamic> json) =>
      _$Model335FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model335ToJson(this);
}
