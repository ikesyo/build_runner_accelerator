import 'package:json_annotation/json_annotation.dart';

part 'model_116.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model116 {
  const Model116({required this.id, required this.value});

  final int id;
  final String value;

  factory Model116.fromJson(Map<String, dynamic> json) =>
      _$Model116FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model116ToJson(this);
}
