import 'package:json_annotation/json_annotation.dart';

part 'model_449.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model449 {
  const Model449({required this.id, required this.value});

  final int id;
  final String value;

  factory Model449.fromJson(Map<String, dynamic> json) =>
      _$Model449FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model449ToJson(this);
}
