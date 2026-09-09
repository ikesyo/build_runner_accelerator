import 'package:json_annotation/json_annotation.dart';

part 'model_226.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model226 {
  const Model226({required this.id, required this.value});

  final int id;
  final String value;

  factory Model226.fromJson(Map<String, dynamic> json) =>
      _$Model226FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model226ToJson(this);
}
