import 'package:json_annotation/json_annotation.dart';

part 'model_076.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model076 {
  const Model076({required this.id, required this.value});

  final int id;
  final String value;

  factory Model076.fromJson(Map<String, dynamic> json) =>
      _$Model076FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model076ToJson(this);
}
