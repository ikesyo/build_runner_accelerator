import 'package:json_annotation/json_annotation.dart';

part 'model_162.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model162 {
  const Model162({required this.id, required this.value});

  final int id;
  final String value;

  factory Model162.fromJson(Map<String, dynamic> json) =>
      _$Model162FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model162ToJson(this);
}
