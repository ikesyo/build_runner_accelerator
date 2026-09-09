import 'package:json_annotation/json_annotation.dart';

part 'model_208.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model208 {
  const Model208({required this.id, required this.value});

  final int id;
  final String value;

  factory Model208.fromJson(Map<String, dynamic> json) =>
      _$Model208FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model208ToJson(this);
}
