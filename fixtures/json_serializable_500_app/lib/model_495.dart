import 'package:json_annotation/json_annotation.dart';

part 'model_495.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model495 {
  const Model495({required this.id, required this.value});

  final int id;
  final String value;

  factory Model495.fromJson(Map<String, dynamic> json) =>
      _$Model495FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model495ToJson(this);
}
