import 'package:json_annotation/json_annotation.dart';

part 'model_261.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model261 {
  const Model261({required this.id, required this.value});

  final int id;
  final String value;

  factory Model261.fromJson(Map<String, dynamic> json) =>
      _$Model261FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model261ToJson(this);
}
