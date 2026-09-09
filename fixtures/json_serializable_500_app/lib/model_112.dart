import 'package:json_annotation/json_annotation.dart';

part 'model_112.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model112 {
  const Model112({required this.id, required this.value});

  final int id;
  final String value;

  factory Model112.fromJson(Map<String, dynamic> json) =>
      _$Model112FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model112ToJson(this);
}
