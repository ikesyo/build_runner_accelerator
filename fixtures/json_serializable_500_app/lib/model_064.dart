import 'package:json_annotation/json_annotation.dart';

part 'model_064.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model064 {
  const Model064({required this.id, required this.value});

  final int id;
  final String value;

  factory Model064.fromJson(Map<String, dynamic> json) =>
      _$Model064FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model064ToJson(this);
}
