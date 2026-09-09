import 'package:json_annotation/json_annotation.dart';

part 'model_328.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model328 {
  const Model328({required this.id, required this.value});

  final int id;
  final String value;

  factory Model328.fromJson(Map<String, dynamic> json) =>
      _$Model328FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model328ToJson(this);
}
