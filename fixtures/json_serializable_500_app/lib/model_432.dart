import 'package:json_annotation/json_annotation.dart';

part 'model_432.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model432 {
  const Model432({required this.id, required this.value});

  final int id;
  final String value;

  factory Model432.fromJson(Map<String, dynamic> json) =>
      _$Model432FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model432ToJson(this);
}
