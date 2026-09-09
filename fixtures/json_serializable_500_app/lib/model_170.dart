import 'package:json_annotation/json_annotation.dart';

part 'model_170.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model170 {
  const Model170({required this.id, required this.value});

  final int id;
  final String value;

  factory Model170.fromJson(Map<String, dynamic> json) =>
      _$Model170FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model170ToJson(this);
}
