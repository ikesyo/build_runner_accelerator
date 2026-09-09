import 'package:json_annotation/json_annotation.dart';

part 'model_230.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model230 {
  const Model230({required this.id, required this.value});

  final int id;
  final String value;

  factory Model230.fromJson(Map<String, dynamic> json) =>
      _$Model230FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model230ToJson(this);
}
