import 'package:json_annotation/json_annotation.dart';

part 'model_357.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model357 {
  const Model357({required this.id, required this.value});

  final int id;
  final String value;

  factory Model357.fromJson(Map<String, dynamic> json) =>
      _$Model357FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model357ToJson(this);
}
