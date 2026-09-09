import 'package:json_annotation/json_annotation.dart';

part 'model_418.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model418 {
  const Model418({required this.id, required this.value});

  final int id;
  final String value;

  factory Model418.fromJson(Map<String, dynamic> json) =>
      _$Model418FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model418ToJson(this);
}
