import 'package:json_annotation/json_annotation.dart';

part 'model_368.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model368 {
  const Model368({required this.id, required this.value});

  final int id;
  final String value;

  factory Model368.fromJson(Map<String, dynamic> json) =>
      _$Model368FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model368ToJson(this);
}
