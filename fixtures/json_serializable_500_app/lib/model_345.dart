import 'package:json_annotation/json_annotation.dart';

part 'model_345.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model345 {
  const Model345({required this.id, required this.value});

  final int id;
  final String value;

  factory Model345.fromJson(Map<String, dynamic> json) =>
      _$Model345FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model345ToJson(this);
}
