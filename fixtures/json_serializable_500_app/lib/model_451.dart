import 'package:json_annotation/json_annotation.dart';

part 'model_451.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model451 {
  const Model451({required this.id, required this.value});

  final int id;
  final String value;

  factory Model451.fromJson(Map<String, dynamic> json) =>
      _$Model451FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model451ToJson(this);
}
